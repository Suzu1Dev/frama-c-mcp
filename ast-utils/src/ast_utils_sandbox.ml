(** ast_utils_sandbox.ml — Sandbox mechanism for CEGIS experimentation.

    Creates disposable copies of functions for annotation experiments.
    Avoids remove_annotation crash by deleting entire sandbox functions
    instead of individual annotations. *)

open Frama_c_kernel
open Cil_types

(* ====== Helpers ====== *)

let short_hash () =
  Random.self_init ();
  Printf.sprintf "%08x" (Random.bits ())

(* ====== Core implementation ====== *)

(** Deep copy a fundec using CIL visitor with refresh behavior.
    Creates fresh stmt IDs, fresh varinfo IDs, and renames to sandbox_name.

    Uses Visitor_behavior.refresh which:
    - Allocates fresh sid for every stmt (via Cil_const.new_raw_sid)
    - Allocates fresh vid for every varinfo declared in the function
    - Memoizes all nodes to maintain internal reference consistency
    - Triggers post-processing (fix_succs_preds, sallstmts rebuild)

    NOTE: This only copies the CIL AST structure. Annotations database
    entries are copied separately by copy_annotations after GFun registration. *)
let copy_fundec original_fundec sandbox_name =
  (* Record original stmt IDs before copy *)
  let orig_sids = List.map (fun s -> s.sid) original_fundec.sallstmts in
  (* Use refresh behavior: deep copy with fresh IDs *)
  let behavior = Visitor_behavior.refresh (Project.current ()) in
  let vis = new Cil.genericCilVisitor behavior in
  let new_fundec = Cil.visitCilFunction vis original_fundec in
  (* Rename: svar already has fresh vid from refresh, just change name *)
  new_fundec.svar.vname <- sandbox_name;
  (* Build sid mapping from original to copy *)
  let new_sids = List.map (fun s -> s.sid) new_fundec.sallstmts in
  (new_fundec, List.combine orig_sids new_sids)

(** Copy all Annotations database entries from original to sandbox.
    Copies code annotations (assert, loop invariant, etc.) and
    function spec (requires, ensures, assigns) from all emitters.
    Requires sandbox_kf to exist (GFun already registered in globals). *)
let copy_annotations original_kf sandbox_kf sid_map =
  let original_fundec = Kernel_function.get_definition original_kf in
  let sandbox_fundec = Kernel_function.get_definition sandbox_kf in
  (* Build orig_sid → sandbox_stmt hashtable *)
  let sandbox_stmt_tbl = Hashtbl.create (List.length sid_map) in
  let sandbox_by_sid = Hashtbl.create (List.length sid_map) in
  List.iter (fun s -> Hashtbl.replace sandbox_by_sid s.sid s)
    sandbox_fundec.sallstmts;
  List.iter (fun (orig_sid, new_sid) ->
    match Hashtbl.find_opt sandbox_by_sid new_sid with
    | Some sandbox_s -> Hashtbl.replace sandbox_stmt_tbl orig_sid sandbox_s
    | None -> ()
  ) sid_map;
  (* Copy code annotations per stmt — collect then add in reverse
     to preserve original ordering (iter_code_annot is LIFO). *)
  List.iter (fun orig_stmt ->
    match Hashtbl.find_opt sandbox_stmt_tbl orig_stmt.sid with
    | Some sandbox_stmt ->
      let annots = ref [] in
      Annotations.iter_code_annot
        (fun emitter ca -> annots := (emitter, ca) :: !annots)
        orig_stmt;
      (* annots is reversed; iterate it to restore original order *)
      List.iter (fun (emitter, ca) ->
        let fresh_ca = Logic_const.refresh_code_annotation ca in
        Annotations.add_code_annot ~keep_empty:false
          emitter ~kf:sandbox_kf sandbox_stmt fresh_ca
      ) !annots
    | None -> ()
  ) original_fundec.sallstmts;
  (* Copy function spec clause-by-clause to avoid behavior name conflicts.
     Sandbox already has a default behavior; we add clauses into it. *)
  let orig_spec = Annotations.funspec original_kf in
  if not (Cil.is_empty_funspec orig_spec) then
    List.iter (fun bhv ->
      Annotations.iter_behaviors_by_emitter
        (fun emitter b ->
          if b.b_name = bhv.b_name then begin
            let bname = bhv.b_name in
            (* For non-default behaviors, register the behavior first *)
            if bname <> Cil.default_behavior_name then
              Annotations.add_behaviors emitter sandbox_kf
                [Cil.mk_behavior ~name:bname ()];
            (* Add individual clauses with refreshed predicates *)
            if bhv.b_assumes <> [] then
              Annotations.add_assumes emitter sandbox_kf ~behavior:bname
                (List.map Logic_const.refresh_predicate bhv.b_assumes);
            if bhv.b_requires <> [] then
              Annotations.add_requires emitter sandbox_kf ~behavior:bname
                (List.map Logic_const.refresh_predicate bhv.b_requires);
            if bhv.b_post_cond <> [] then
              Annotations.add_ensures emitter sandbox_kf ~behavior:bname
                (List.map (fun (tk, ip) ->
                  (tk, Logic_const.refresh_predicate ip)
                ) bhv.b_post_cond);
            (match bhv.b_assigns with
             | WritesAny -> ()
             | Writes _ ->
               Annotations.add_assigns ~keep_empty:false emitter sandbox_kf
                 ~behavior:bname bhv.b_assigns)
          end)
        original_kf
    ) orig_spec.spec_behavior;
  List.iter
    (Annotations.add_complete Emitter.end_user sandbox_kf)
    orig_spec.spec_complete_behaviors;
  List.iter
    (Annotations.add_disjoint Emitter.end_user sandbox_kf)
    orig_spec.spec_disjoint_behaviors;
  (* fsmint-7 A2: copy funspec-level terminates / decreases —— funspec top-level single value clause,
     Not in any behavior, the behavior copy loop above misses them (the same missing fields as insert_spec).
     It is needed so that terminates \false waiver can be copied into the sandbox when create_sandbox extracts the function from main.
     → Incremental revalidation sandbox is naturally inherited; otherwise terminates goal returns to kernel default \true.
     Use the same "keep original emitter" pattern (iter_* gives the original emitter, add_* reuses it). *)
  (* sandbox is new deep-copy, funspec is clean (no existing terminates/decreases) → add directly,
     **No need for ~force**: force=true will first try to delete non-existing clauses → remove_in_funspec assert false. *)
  Annotations.iter_terminates
    (fun emitter ip ->
       Annotations.add_terminates emitter sandbox_kf
         (Logic_const.refresh_predicate ip))
    original_kf;
  Annotations.iter_decreases
    (fun emitter v ->
       Annotations.add_decreases emitter sandbox_kf v)
    original_kf

(** Internal: create sandbox with a specific name (for reset reuse). *)
let create_sandbox_impl kf sandbox_name =
  try
    let fundec = Kernel_function.get_definition kf in
    (* 1. Deep copy fundec *)
    let (new_fundec, sid_map) = copy_fundec fundec sandbox_name in
    (* 2. Register in AST globals + Globals.Functions table *)
    let loc = Kernel_function.get_location kf in
    let new_global = GFun (new_fundec, loc) in
    let file = Ast.get () in
    file.globals <- file.globals @ [new_global];
    Globals.Functions.add (Cil_types.Definition (new_fundec, loc));
    Ast.mark_as_changed ();
    (* 2b. Force property initialization for sandbox function.
       Without this, WP's first startProofs triggers AbortFatal because
       the sandbox kf was created outside Frama-C's normal parse pipeline
       and Property_status tables are not populated. *)
    let sandbox_kf = Globals.Functions.get new_fundec.svar in
    (try Populate_spec.populate_funspec sandbox_kf [`Assigns]
     with _ -> ());
    (* 3. Copy annotations from original to sandbox *)
    copy_annotations kf sandbox_kf sid_map;
    Ok (sandbox_name, sid_map)
  with
  | Kernel_function.No_Definition ->
    Error (Printf.sprintf "function '%s' has no definition"
             (Kernel_function.get_name kf))
  | exn ->
    Error (Printf.sprintf "create_sandbox failed: %s"
             (Printexc.to_string exn))

(* ====== Public API ====== *)

(** Create a sandbox copy of a function.
    Returns (sandbox_name, sid_map) where sid_map is
    (original_sid, sandbox_sid) list. *)
let create_sandbox kf =
  let original_name = Kernel_function.get_name kf in
  let hash = short_hash () in
  let sandbox_name =
    Printf.sprintf "__sandbox__%s_%s" original_name hash in
  match create_sandbox_impl kf sandbox_name with
  | Ok (name, sid_map) -> Ok (name, hash, sid_map)
  | Error msg -> Error msg

(** Delete a sandbox function from AST globals.
    Idempotent: returns Ok () even if not found. *)
let delete_sandbox sandbox_name =
  let file = Ast.get () in
  let found = ref false in
  file.globals <- List.filter (fun g ->
    match g with
    | GFun (fd, _) when fd.svar.vname = sandbox_name ->
      found := true; false
    | GFunDecl (_, vi, _) when vi.vname = sandbox_name ->
      false
    | _ -> true
  ) file.globals;
  if !found then
    Ast.mark_as_changed ();
  Ok ()

(** The ACSL names this plug-in's emitter wrote on one function's clauses.

    Ground truth for "did this server write it", which the server side cannot
    work out for itself: it sees a property row carrying names, and a generated
    label merely looks like one of ours. Emitter identity is what Frama-C
    actually records, and it is the same test extract_our_annotations already
    depends on.

    Names rather than markers, because the plug-in cannot produce the server's
    own property tags: those are allocated per process by the tag table when the
    property list is serialized, and Property.pretty gives a description
    instead. So the join happens on the ACSL name, which is what a property row
    carries in its names field. *)
let our_clause_names kf =
  let emitter = Ast_utils_core.emitter in
  let names = ref [] in
  let add_predicate p = names := List.rev_append p.pred_name !names in
  let add_identified ip = add_predicate ip.ip_content.tp_statement in
  let add_behavior e bhv =
    if Emitter.equal e emitter then begin
      List.iter add_identified bhv.b_requires;
      List.iter add_identified bhv.b_assumes;
      List.iter (fun (_, ip) -> add_identified ip) bhv.b_post_cond
    end
  in
  let add_code_annot e ca =
    if Emitter.equal e emitter then
      match ca.annot_content with
      | AAssert (_, tp) | AInvariant (_, _, tp) -> add_predicate tp.tp_statement
      | _ -> ()
  in
  Annotations.iter_behaviors_by_emitter add_behavior kf;
  (* A declaration has no code annotations to own, and asking for a definition
     this plug-in does not have is not an error here. *)
  if Kernel_function.is_definition kf then
    List.iter
      (Annotations.iter_code_annot add_code_annot)
      (Kernel_function.get_definition kf).sallstmts;
  List.sort_uniq String.compare !names

(** Extract annotations added by our emitter from a sandbox function.
    Returns (sandbox_sid, annotation_text) list. *)
let extract_our_annotations sandbox_kf =
  let emitter = Ast_utils_core.emitter in
  try
    let fundec = Kernel_function.get_definition sandbox_kf in
    let result = ref [] in
    (* 1. Extract funspec (requires/ensures/assigns) *)
    Annotations.iter_behaviors_by_emitter
      (fun e bhv ->
        if Emitter.equal e emitter then begin
          let text = Format.asprintf "%a"
            Printer.pp_behavior bhv in
          (* sid = -1 signals funspec (not statement-level) *)
          result := (-1, text) :: !result
        end)
      sandbox_kf;
    (* 2. Extract code annotations (loop invariant, assert, etc.) *)
    List.iter (fun stmt ->
      Annotations.iter_code_annot
        (fun e ca ->
          if Emitter.equal e emitter then begin
            let text = Format.asprintf "%a"
              Printer.pp_code_annotation ca in
            result := (stmt.sid, text) :: !result
          end)
        stmt
    ) fundec.sallstmts;
    Ok (List.rev !result)
  with
  | Kernel_function.No_Definition ->
    Error "sandbox function has no definition"
  | exn ->
    Error (Printexc.to_string exn)
