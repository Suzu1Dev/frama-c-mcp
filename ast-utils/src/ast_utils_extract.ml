(** ast_utils_extract.ml — Extract a function with all its dependencies.

    Given a kernel_function, recursively collects all type definitions,
    global variables, and callee declarations (with contracts) needed to
    produce a self-contained C file that Frama-C can independently parse.

    Used by the sandbox v2 mechanism: the output file is loaded by a
    separate Frama-C instance for isolated WP verification. *)

open Frama_c_kernel
open Cil_types

(* ====== Collected state ====== *)

type collected = {
  comp_keys : (int, unit) Hashtbl.t;        (* compinfo.ckey *)
  enum_names : (string, unit) Hashtbl.t;     (* enuminfo.ename *)
  type_names : (string, unit) Hashtbl.t;     (* typeinfo.tname *)
  var_vids : (int, unit) Hashtbl.t;          (* varinfo.vid for globals *)
  fun_vids : (int, unit) Hashtbl.t;          (* varinfo.vid for callees *)
  var_decl_vids : (int, unit) Hashtbl.t;     (* ACSL-only global var decls *)
  fun_decl_vids : (int, unit) Hashtbl.t;     (* ACSL-only function decls *)
  mutable comps : compinfo list;             (* collected structs/unions *)
  mutable enums : enuminfo list;
  mutable types : (typeinfo * global) list;  (* typeinfo + original GType *)
  mutable vars : global list;                (* GVar / GVarDecl *)
  mutable funs : global list;                (* GFunDecl with spec *)
}

let create_collected () = {
  comp_keys = Hashtbl.create 16;
  enum_names = Hashtbl.create 16;
  type_names = Hashtbl.create 16;
  var_vids = Hashtbl.create 16;
  fun_vids = Hashtbl.create 16;
  var_decl_vids = Hashtbl.create 16;
  fun_decl_vids = Hashtbl.create 16;
  comps = []; enums = []; types = []; vars = []; funs = [];
}

(* ====== Type collection ====== *)

(** Recursively collect all type dependencies from a CIL type. *)
let rec collect_type col typ =
  (* First check for TNamed BEFORE unrolling, to preserve typedef declarations *)
  (match typ.tnode with
   | TNamed ti ->
     if not (Hashtbl.mem col.type_names ti.tname) then begin
       Hashtbl.replace col.type_names ti.tname ();
       (* Recurse into the underlying type *)
       collect_type col ti.ttype;
       (* Find the original GType global for this typeinfo *)
       let file = Ast.get () in
       let gtype = List.find_opt (fun g ->
         match g with
         | GType (ti2, _) -> ti2.tname = ti.tname
         | _ -> false
       ) file.globals in
       (match gtype with
        | Some gt -> col.types <- (ti, gt) :: col.types
        | None -> ()) (* built-in typedef, skip *)
     end
   | _ -> ());
  (* Then unroll and recurse into structural types *)
  match Ast_types.unroll_node typ with
  | TComp ci ->
    if not (Hashtbl.mem col.comp_keys ci.ckey) then begin
      Hashtbl.replace col.comp_keys ci.ckey ();
      (* Recurse into field types first *)
      Option.iter
        (List.iter (fun fi -> collect_type col fi.ftype)) ci.cfields;
      col.comps <- ci :: col.comps
    end
  | TEnum ei ->
    if not (Hashtbl.mem col.enum_names ei.ename) then begin
      Hashtbl.replace col.enum_names ei.ename ();
      col.enums <- ei :: col.enums
    end
  | TNamed _ -> () (* already handled above *)
  | TPtr inner ->
    collect_type col inner
  | TArray (elem, _) ->
    collect_type col elem
  | TFun (ret, params, _) ->
    collect_type col ret;
    (match params with
     | Some args ->
       List.iter (fun (_, t, _) -> collect_type col t) args
     | None -> ())
  | _ -> () (* TInt, TFloat, TVoid, TVaList — no deps *)

let find_global_var vi =
  List.find_opt (fun g ->
    match g with
    | GVar (vi2, _, _) -> vi2.vid = vi.vid
    | GVarDecl (vi2, _) -> vi2.vid = vi.vid
    | _ -> false
  ) (Ast.get ()).globals

(* Deliberately not merged with collect_global_var below.

   The shape is nearly the same, and the difference is the memo table: this one
   guards on var_decl_vids, which tracks globals a contract mentions, while
   collect_global_var guards on var_vids, which tracks globals the code
   touches. Sharing one table would change what the extracted file contains
   rather than only where the code lives, so the duplication is the cheaper of
   the two costs. *)
let collect_acsl_global_var col vi =
  if not (Hashtbl.mem col.var_decl_vids vi.vid) then begin
    Hashtbl.replace col.var_decl_vids vi.vid ();
    collect_type col vi.vtype;
    match find_global_var vi with
    | Some gv -> col.vars <- gv :: col.vars
    | None -> ()
  end

let collect_acsl_function_decl col vi =
  if not (Hashtbl.mem col.fun_decl_vids vi.vid) then begin
    Hashtbl.replace col.fun_decl_vids vi.vid ();
    collect_type col vi.vtype
  end

let collect_acsl_varinfo col vi =
  if vi.vglob then
    if Ast_types.is_fun vi.vtype then
      collect_acsl_function_decl col vi
    else
      collect_acsl_global_var col vi

class collect_acsl_visitor col = object
  inherit Cil.nopCilVisitor

  method! vvrbl vi =
    collect_acsl_varinfo col vi;
    DoChildren

  method! vterm_lhost = function
    | TVar { lv_origin = Some vi; _ } ->
      collect_acsl_varinfo col vi;
      DoChildren
    | _ -> DoChildren

  method! vtype typ =
    collect_type col typ;
    SkipChildren

  method! vlogic_type lt =
    (match lt with
     | Ctype typ -> collect_type col typ
     | _ -> ());
    DoChildren
end

(** Collect dependencies that appear only inside ACSL.
    Callee contracts can mention C types/globals or logic definitions that do
    not appear in public C signatures or C bodies. *)
let collect_funspec col spec =
  if not (Cil.is_empty_funspec spec) then
    ignore (Cil.visitCilFunspec (new collect_acsl_visitor col) spec)

let collect_global_annotations col =
  let vis = new collect_acsl_visitor col in
  List.iter (fun g ->
    match g with
    | GAnnot (ga, _) ->
      ignore (Cil.visitCilAnnotation (vis :> Cil.cilVisitor) ga)
    | _ -> ()
  ) (Ast.get ()).globals

(* ====== Callee emission ====== *)

(* The callsite varinfo is not always the one the function table is keyed on:
   an argument cast makes CIL build a second varinfo for the same function, so
   lookup by identity misses where lookup by name still hits. Both raise
   Not_found, and what an unregistered callee means differs by caller, so this
   answers None and lets the caller decide. *)
let resolve_callee vi =
  match Globals.Functions.get vi with
  | kf -> Some kf
  | exception Not_found ->
    (match Globals.Functions.find_by_name vi.vname with
     | kf -> Some kf
     | exception Not_found -> None)

(* Emit a callee as an empty body rather than as a declaration.
   Two callers want this for one reason. A bare declaration without assigns
   defaults to assigns \nothing, which the WP manual describes as best effort
   and unsafe, so a proof above it would rest on the callee writing nothing at
   all; an empty body says nothing instead of saying something false. The other
   caller has a definition it does not want to drag in, and needs the same
   silence. The spec still goes out ahead of the body when there is one, and
   the formals are rebuilt from the type because emptyFunction creates none. *)
let emit_empty_stub col spec callee_vi loc =
  if not (Cil.is_empty_funspec spec) then
    col.funs <- GFunDecl (spec, callee_vi, loc) :: col.funs;
  let empty_fundec = Cil.emptyFunction callee_vi.vname in
  empty_fundec.svar <- callee_vi;
  (match Ast_types.unroll_node callee_vi.vtype with
   | TFun (_, Some args, _) ->
     let formals = List.mapi (fun i (name, typ, _attrs) ->
       let vname = if name = "" then Printf.sprintf "_arg%d" i else name in
       Cil.makeFormalVar empty_fundec vname typ
     ) args in
     Cil.setFormals empty_fundec formals
   | _ -> ());
  col.funs <- GFun (empty_fundec, loc) :: col.funs

(* ====== Function body visitor ====== *)

(* Collect one referenced global and everything its initializer reaches.

   The recursion into the initializer is the part worth keeping in one place:
   a global whose initializer mentions another global, or takes the size of a
   type, drags that dependency into the extracted file, and a copy that
   forgets to recurse produces a file that does not parse. Guarded on var_vids
   so a diamond of initializers terminates.

   The recursion arrives as an argument because the visitor that performs it is
   defined below and one of the two callers is inside it. *)
let collect_global_var col ~visit_init vi =
  if not (Hashtbl.mem col.var_vids vi.vid) then begin
    Hashtbl.replace col.var_vids vi.vid ();
    collect_type col vi.vtype;
    match find_global_var vi with
    | Some (GVar (_, initinfo, _) as gv) ->
      col.vars <- gv :: col.vars;
      (match initinfo.init with
       | Some init -> visit_init vi init
       | None -> ())
    | Some gv -> col.vars <- gv :: col.vars
    | None -> ()
  end

(** CIL visitor for global variable initializer expressions.
    Collects other global variables and types referenced in initializers.
    Lighter than collect_visitor — only handles variable/type references,
    not function calls (initializers can't call functions in C). *)
class collect_init_visitor col ~target_vid = object
  inherit Cil.nopCilVisitor

  method! vexpr e =
    (match e.enode with
     | Const (CEnum {eihost = ei; _}) ->
       if not (Hashtbl.mem col.enum_names ei.ename) then begin
         Hashtbl.replace col.enum_names ei.ename ();
         col.enums <- ei :: col.enums
       end
     | SizeOfE _ | AlignOfE _ -> ()  (* handled by children *)
     | _ -> ());
    DoChildren

  method! vtype typ =
    collect_type col typ;
    SkipChildren

  method! vlval = function
    | (Var vi, _) when vi.vglob && vi.vid <> target_vid
                      && Ast_types.is_fun vi.vtype ->
      (* Function pointer reference inside initializer (e.g. &parse_func in dispatch table) *)
      if not (Hashtbl.mem col.fun_vids vi.vid) then begin
        Hashtbl.replace col.fun_vids vi.vid ();
        collect_type col vi.vtype;
        (match resolve_callee vi with
         | Some callee_kf ->
           let spec = Annotations.funspec callee_kf in
           collect_funspec col spec;
           let callee_vi = Kernel_function.get_vi callee_kf in
           let loc = Kernel_function.get_location callee_kf in
           if Kernel_function.is_definition callee_kf then
             emit_empty_stub col spec callee_vi loc
           else
             col.funs <- GFunDecl (spec, callee_vi, loc) :: col.funs
         | None ->
           (* Not registered, so a bare declaration is all there is to emit. *)
           col.funs <- GFunDecl (Cil.empty_funspec (), vi, Ast_utils_compat.loc_unknown) :: col.funs)
      end;
      DoChildren
    | (Var vi, _) when vi.vglob && vi.vid <> target_vid ->
      (* Global variable reference inside initializer *)
      collect_global_var col vi
        ~visit_init:(fun vi init ->
          ignore (Cil.visitCilInit_or_str
                    (new collect_init_visitor col ~target_vid) vi init));
      DoChildren
    | _ -> DoChildren
end

(** CIL visitor that collects callee functions and global variables
    referenced in the function body. *)
class collect_visitor col ~target_vid = object(self)
  inherit Cil.nopCilVisitor

  (* Emit one callee. The canonical varinfo from Kernel_function.get_vi is
     what goes out, not the callsite vi, which may carry a type distorted by
     argument casts. A callee that resolves nowhere is dropped: the extracted
     file cannot say anything useful about a function the project does not
     hold. *)
  method private collect_callee vi =
    match resolve_callee vi with
    | None -> ()
    | Some callee_kf ->
      let spec = Annotations.funspec callee_kf in
      collect_funspec col spec;
      let callee_vi = Kernel_function.get_vi callee_kf in
      let loc = Kernel_function.get_location callee_kf in
      let has_assigns = List.exists (fun bhv ->
        match bhv.b_assigns with
        | WritesAny -> false
        | Writes _ -> true
      ) spec.spec_behavior in
      if has_assigns then
        if Kernel_function.is_definition callee_kf then
          col.funs <- GFun (Kernel_function.get_definition callee_kf, loc) :: col.funs
        else
          col.funs <- GFunDecl (spec, callee_vi, loc) :: col.funs
      else
        emit_empty_stub col spec callee_vi loc

  (* vvrbl intercepts function references that arrive via CIL's
     Local_init / ConsInit path (e.g. `int m = f(args)` — CIL normalises
     this into a block-local init and visits the callee varinfo through
     visitCilVarUse → vvrbl, NOT through vlval). *)
  method! vvrbl vi =
    if vi.vglob && Ast_types.is_fun vi.vtype && vi.vid <> target_vid
       && not (Hashtbl.mem col.fun_vids vi.vid)
    then begin
      Hashtbl.replace col.fun_vids vi.vid ();
      collect_type col vi.vtype;
      self#collect_callee vi
    end;
    DoChildren

  method! vexpr e =
    (match e.enode with
     | Const (CEnum {eihost = ei; _}) ->
       (* Enum constant reference — collect the enum type *)
       if not (Hashtbl.mem col.enum_names ei.ename) then begin
         Hashtbl.replace col.enum_names ei.ename ();
         col.enums <- ei :: col.enums
       end
     | _ -> ());
    DoChildren

  method! vlval = function
    | (Var vi, _) when vi.vglob && Ast_types.is_fun vi.vtype
                      && vi.vid <> target_vid ->
      (* Function reference via direct Call instruction.
         Excluding target function itself to avoid duplicate definition
         in recursive cases. *)
      if not (Hashtbl.mem col.fun_vids vi.vid) then begin
        Hashtbl.replace col.fun_vids vi.vid ();
        collect_type col vi.vtype;
        self#collect_callee vi
      end;
      DoChildren
    | (Var vi, _) when vi.vglob ->
      (* Global variable reference *)
      collect_global_var col vi
        ~visit_init:(fun vi init ->
          ignore (Cil.visitCilInit_or_str
                    (new collect_init_visitor col ~target_vid) vi init));
      DoChildren
    | _ -> DoChildren
end

(* ====== Output generation ====== *)

(** Print #include directives — same logic as Cil_printer.print_std_includes *)
let print_includes fmt =
  let extract_file acc = function
    | AStr s -> Datatype.String.Set.add Filepath.(to_string (of_string s)) acc
    | _ -> acc in
  let add_file acc g =
    Ast_attributes.(find_params fc_stdlib (Cil_datatype.Global.attr g))
    |> List.fold_left extract_file acc in
  let includes = List.fold_left add_file
    Datatype.String.Set.empty (Ast.get ()).globals in
  Datatype.String.Set.iter (fun s ->
    Format.fprintf fmt "#include \"%s\"@." s) includes;
  if not (Datatype.String.Set.is_empty includes) then
    Format.fprintf fmt "@."

let print_bare_fun_decl fmt vi =
  Format.fprintf fmt "%a@." Printer.pp_global
    (GFunDecl (Cil.empty_funspec (), vi, Ast_utils_compat.loc_unknown))

let print_global_var fmt g =
  match g with
  | GVar (vi, _, loc) ->
    Format.fprintf fmt "%a@." Printer.pp_global (GVarDecl (vi, loc))
  | GVarDecl _ ->
    Format.fprintf fmt "%a@." Printer.pp_global g
  | _ -> ()

(** Check if a global is a dependency collected in [col].
    Note: GFun (full function definitions) from Ast.get().globals are NOT matched
    for callees — callee output uses col.funs (empty stubs/declarations), not the
    original full definitions. Only types and variables come from Ast.get().globals. *)
let is_collected_dep col g =
  match g with
  | GEnumTag (ei, _) | GEnumTagDecl (ei, _) ->
    Hashtbl.mem col.enum_names ei.ename
  | GCompTag (ci, _) | GCompTagDecl (ci, _) ->
    Hashtbl.mem col.comp_keys ci.ckey
  | GType (ti, _) ->
    Hashtbl.mem col.type_names ti.tname
  | GVar (vi, _, _) | GVarDecl (vi, _) ->
    Hashtbl.mem col.var_vids vi.vid
    || Hashtbl.mem col.var_decl_vids vi.vid
  | _ -> false

let is_collected_full_var col vi =
  Hashtbl.mem col.var_vids vi.vid

let is_collected_decl_var col vi =
  Hashtbl.mem col.var_decl_vids vi.vid

let report_item kind name =
  `Assoc [("kind", `String kind); ("name", `String name)]

let type_report col =
  let items = List.filter_map (fun g ->
    match g with
    | GEnumTag (ei, _) | GEnumTagDecl (ei, _) ->
      if is_collected_dep col g then Some (report_item "enum" ei.ename) else None
    | GCompTag (ci, _) | GCompTagDecl (ci, _) ->
      let kind = if ci.cstruct then "struct" else "union" in
      if is_collected_dep col g then Some (report_item kind ci.cname) else None
    | GType (ti, _) ->
      if is_collected_dep col g then Some (report_item "typedef" ti.tname) else None
    | _ -> None
  ) (Ast.get ()).globals in
  `List items

let global_var_report col =
  let items = List.filter_map (fun g ->
    match g with
    | GVar (vi, _, _) | GVarDecl (vi, _) ->
      if is_collected_full_var col vi then
        Some (report_item "definition" vi.vname)
      else if is_collected_decl_var col vi then
        Some (report_item "declaration" vi.vname)
      else None
    | _ -> None
  ) (Ast.get ()).globals in
  `List items

let callee_report col =
  let items = List.filter_map (function
    | GFun ({svar = vi; sbody = {bstmts = []; _}; _}, _) ->
      Some (report_item "empty_stub" vi.vname)
    | GFun ({svar = vi; _}, _) ->
      Some (report_item "definition" vi.vname)
    | GFunDecl (_, vi, _) ->
      Some (report_item "declaration" vi.vname)
    | _ -> None
  ) (List.rev col.funs) in
  `List items

let global_acsl_report () =
  let one ga =
    match ga with
    | Dfun_or_pred (li, _) ->
      let name = li.l_var_info.lv_name in
      let kind = match li.l_body, li.l_type with
        | LBinductive _, _ -> "inductive"
        | _, None -> "predicate"
        | _, Some _ -> "logic_function" in
      Some (report_item kind name)
    | Daxiomatic (name, defs, _, _) ->
      Some (`Assoc [
        ("kind", `String "axiomatic");
        ("name", `String name);
        ("items", `Int (List.length defs));
      ])
    | Dlemma (name, _, _, _, _, _) ->
      Some (report_item "lemma" name)
    | Dtype (lti, _) ->
      Some (report_item "logic_type" lti.lt_name)
    | _ -> Some (report_item "global_annotation" "")
  in
  let items = List.filter_map (function
    | GAnnot (ga, _) -> one ga
    | _ -> None
  ) (Ast.get ()).globals in
  (`List items, List.length items)

let extraction_report col target_name =
  let acsl, acsl_count = global_acsl_report () in
  `Assoc [
    ("target", `String target_name);
    ("types", type_report col);
    ("globals", global_var_report col);
    ("callees", callee_report col);
    ("copied_global_acsl", acsl);
    ("copied_global_acsl_count", `Int acsl_count);
    ("skipped_declarations", `List []);
  ]

(** Generate a self-contained C file for a single function + dependencies.
    Single pass over Ast.get().globals ensures source declaration order.
    Only outputs globals that [col] recorded as dependencies. *)
let generate_output col target_global =
  let buf = Buffer.create 4096 in
  let fmt = Format.formatter_of_buffer buf in
  print_includes fmt;
  (* Phase 1: types in source declaration order *)
  List.iter (fun g -> match g with
    | GEnumTag _ | GEnumTagDecl _ | GCompTag _ | GCompTagDecl _ | GType _ ->
      if is_collected_dep col g then
        Format.fprintf fmt "%a@." Printer.pp_global g
    | _ -> ()
  ) (Ast.get ()).globals;
  Format.fprintf fmt "@.";
  (* Phase 2: forward declarations for callee functions —
     needed before global variables that reference function pointers
     (e.g. dispatch tables: .handler = &parse_func) *)
  let callee_decls = Hashtbl.create 16 in
  List.iter (fun gf -> match gf with
    | GFunDecl (_, vi, _) | GFun ({svar = vi; _}, _) ->
      if not (Hashtbl.mem callee_decls vi.vid) then begin
        Hashtbl.replace callee_decls vi.vid ();
        print_bare_fun_decl fmt vi
      end
    | _ -> ()
  ) col.funs;
  List.iter (fun g -> match g with
    | GFunDecl (_, vi, _) | GFun ({svar = vi; _}, _) ->
      if Hashtbl.mem col.fun_decl_vids vi.vid
         && not (Hashtbl.mem callee_decls vi.vid)
      then begin
        Hashtbl.replace callee_decls vi.vid ();
        print_bare_fun_decl fmt vi
      end
    | _ -> ()
  ) (Ast.get ()).globals;
  Format.fprintf fmt "@.";
  (* Phase 3: global variables in source declaration order *)
  List.iter (fun g -> match g with
    | GVar (vi, _, _) | GVarDecl (vi, _) ->
      if is_collected_full_var col vi then
        Format.fprintf fmt "%a@." Printer.pp_global g
      else if is_collected_decl_var col vi then
        print_global_var fmt g
    | _ -> ()
  ) (Ast.get ()).globals;
  Format.fprintf fmt "@.";
  (* Phase 4: ambient ACSL global definitions. They must be available before
     sandbox contracts reference them or insert new annotations using them. *)
  List.iter (fun g -> match g with
    | GAnnot _ -> Format.fprintf fmt "%a@." Printer.pp_global g
    | _ -> ()
  ) (Ast.get ()).globals;
  Format.fprintf fmt "@.";
  (* Phase 5: callee functions with specs/stubs *)
  let funs = List.rev col.funs in
  List.iter (fun gf ->
    Format.fprintf fmt "%a@." Printer.pp_global gf
  ) funs;
  if funs <> [] then Format.fprintf fmt "@.";
  (* Target function last *)
  Format.fprintf fmt "%a@." Printer.pp_global target_global;
  Format.pp_print_flush fmt ();
  Buffer.contents buf

(* ====== Public API ====== *)

(** Extract a function and all its dependencies as a self-contained C string.
    The output can be parsed by a standalone Frama-C instance.
    Also returns the sallstmts SID list for SID mapping and dependency report. *)
let extract kf =
  try
    let fundec = Kernel_function.get_definition kf in
    let loc = Kernel_function.get_location kf in
    let col = create_collected () in
    (* Collect types from function signature *)
    collect_type col (Kernel_function.get_return_type kf);
    List.iter (fun vi -> collect_type col vi.vtype) fundec.sformals;
    List.iter (fun vi -> collect_type col vi.vtype) fundec.slocals;
    collect_global_annotations col;
    collect_funspec col (Annotations.funspec kf);
    (* Collect callees and globals from function body *)
    let target_vid = (Kernel_function.get_vi kf).vid in
    let vis = new collect_visitor col ~target_vid in
    ignore (Cil.visitCilFunction vis fundec);
    (* Generate output *)
    let target_global = GFun (fundec, loc) in
    let source = generate_output col target_global in
    (* Extract sallstmts SID list — authoritative order for SID mapping *)
    let sids = List.map (fun s -> s.sid) fundec.sallstmts in
    Ok (source, sids, extraction_report col (Kernel_function.get_name kf))
  with
  | Kernel_function.No_Definition ->
    Error (Printf.sprintf "function '%s' has no definition"
             (Kernel_function.get_name kf))
  | exn ->
    Error (Printf.sprintf "extract failed: %s" (Printexc.to_string exn))
