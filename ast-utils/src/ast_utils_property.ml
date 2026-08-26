(** ast_utils_property.ml -- what a WP property or proof step says, as JSON.
    
    Split out of ast_utils_register.ml, which had grown into 30 request
    registrations with this analysis interleaved between them. Registering a
    request and deciding how a proof step serializes are separate jobs, and a
    file that hosts both is reopened by every change to either. Nothing here
    depends on the registration code: it moved verbatim. *)

open Frama_c_kernel
open Cil_types

let pp_pred_to_string p =
  Format.asprintf "%a" Wp.Lang.F.pp_pred p

let json_string_list items =
  `List (List.map (fun item -> `String item) items)

let kinstr_to_json = function
  | Kglobal -> `Assoc [("kind", `String "global")]
  | Kstmt stmt -> `Assoc [
    ("kind", `String "stmt");
    ("sid", `Int stmt.sid);
    ("loc", Ast_utils_ast.loc_to_json (Cil_datatype.Stmt.loc stmt));
  ]

let term_kind_to_string =
  Cil_printer.get_termination_kind_name

let rec clause_metadata_of_property prop =
  let loc = Property.location prop in
  let loc_source =
    if Ast_utils_compat.loc_is_unknown loc then "unknown"
    else "property"
  in
  let names = Property.get_names prop in
  let for_behaviors = Property.get_for_behaviors prop in
  let base_fields kind = [
    ("kind", `String kind);
    ("metadata_source", `String "frama-c-property");
    ("loc", Ast_utils_ast.loc_to_json loc);
    ("loc_source", `String loc_source);
    ("kinstr", kinstr_to_json (Property.get_kinstr prop));
    ("property_names", json_string_list names);
    ("for_behaviors", json_string_list for_behaviors);
  ] in
  let with_behavior behavior fields =
    ("behavior", `String behavior.b_name) :: fields
  in
  match prop with
  | Property.IPPredicate {ip_kind; ip_pred; _} ->
    let pred_id = ("predicate_id", `Int ip_pred.ip_id) in
    (match ip_kind with
     | Property.PKRequires behavior ->
       `Assoc (pred_id :: with_behavior behavior (base_fields "requires"))
     | Property.PKAssumes behavior ->
       `Assoc (pred_id :: with_behavior behavior (base_fields "assumes"))
     | Property.PKEnsures (behavior, term_kind) ->
       `Assoc (pred_id
               :: ("termination", `String (term_kind_to_string term_kind))
               :: with_behavior behavior (base_fields "ensures"))
     | Property.PKTerminates ->
       `Assoc (pred_id :: base_fields "terminates"))
  | Property.IPCodeAnnot {ica_stmt; ica_ca; _} ->
    let annot_id = ("annotation_id", `Int ica_ca.annot_id) in
    let stmt_id = ("stmt_id", `Int ica_stmt.sid) in
    let kind =
      match ica_ca.annot_content with
      | AAssert _ -> "assert"
      | AInvariant (_, true, _) -> "loop_invariant"
      | AInvariant (_, false, _) -> "invariant_assert"
      | AStmtSpec _ -> "stmt_contract"
      | AVariant _ -> "loop_variant"
      | AAssigns _ -> "loop_assigns"
      | AAllocation _ -> "loop_allocation"
      | AExtended _ -> "extended"
    in
    `Assoc (annot_id :: stmt_id :: base_fields kind)
  | Property.IPAssigns _ -> `Assoc (base_fields "assigns")
  | Property.IPFrom _ -> `Assoc (base_fields "from")
  | Property.IPAllocation _ -> `Assoc (base_fields "allocates")
  | Property.IPDecrease _ -> `Assoc (base_fields "variant")
  | Property.IPBehavior _ -> `Assoc (base_fields "behavior")
  | Property.IPComplete _ -> `Assoc (base_fields "complete_behaviors")
  | Property.IPDisjoint _ -> `Assoc (base_fields "disjoint_behaviors")
  | Property.IPReachable _ -> `Assoc (base_fields "reachable")
  | Property.IPPropertyInstance {ii_ip; _} ->
    (match clause_metadata_of_property ii_ip with
     | `Assoc fields ->
       let fields = List.remove_assoc "metadata_source" fields in
       `Assoc (("metadata_source", `String "frama-c-property-instance") :: fields)
     | json -> json)
  | Property.IPLemma _ -> `Assoc (base_fields "lemma")
  | Property.IPAxiomatic _ -> `Assoc (base_fields "axiomatic")
  | Property.IPModule _ -> `Assoc (base_fields "module")
  | Property.IPExtended _ -> `Assoc (base_fields "extended")
  | Property.IPTypeInvariant _ -> `Assoc (base_fields "type_invariant")
  | Property.IPGlobalInvariant _ -> `Assoc (base_fields "global_invariant")
  | Property.IPOther _ -> `Assoc (base_fields "other")

let variables_of_property prop =
  let names_of_predicate pred =
    let vars = Cil.extract_free_logicvars_from_predicate pred in
    Cil_datatype.Logic_var.Set.fold
      (fun lv acc ->
         if lv.lv_name = "" || List.mem lv.lv_name acc then acc
         else lv.lv_name :: acc)
      vars
      []
    |> List.sort String.compare
  in
  let names =
    match prop with
    | Property.IPPredicate {ip_pred; _} ->
      names_of_predicate (Logic_const.pred_of_id_pred ip_pred)
    | Property.IPCodeAnnot {ica_ca={annot_content=AAssert (_, tp); _}; _} ->
      names_of_predicate tp.tp_statement
    | Property.IPCodeAnnot {ica_ca={annot_content=AInvariant (_, _, tp); _}; _} ->
      names_of_predicate tp.tp_statement
    | Property.IPPropertyInstance {ii_pred=Some ip; _} ->
      names_of_predicate (Logic_const.pred_of_id_pred ip)
    | _ -> []
  in
  `Assoc [
    ("source", `String "acsl-property-ast");
    ("names", json_string_list names);
  ]

let callee_info_at_stmt stmt =
  let direct vi loc =
    match Ast_utils_ast.kernel_function_of_varinfo vi with
    | Some callee ->
      ([`Assoc [
        ("sid", `Int stmt.sid);
        ("loc", Ast_utils_ast.loc_to_json loc);
        ("callee", Ast_utils_ast.function_contract_to_json callee);
      ]], [])
    | None -> ([], [`Assoc [
      ("sid", `Int stmt.sid);
      ("loc", Ast_utils_ast.loc_to_json loc);
      ("callee", `String vi.vname);
    ]])
  in
  match stmt.skind with
  | Instr (Call (_, Var vi, _, loc)) -> direct vi loc
  | Instr (Call (_, fn, _, loc)) ->
    ([], [`Assoc [
      ("sid", `Int stmt.sid);
      ("loc", Ast_utils_ast.loc_to_json loc);
      ("callee", `String (Format.asprintf "%a" Printer.pp_lhost fn));
    ]])
  | Instr (Local_init (_, ConsInit (vi, _, _), loc)) -> direct vi loc
  | _ -> ([], [])

let callee_context_of_property prop =
  match prop with
  | Property.IPPropertyInstance {ii_stmt; ii_ip; _} ->
    let contracts, unresolved = callee_info_at_stmt ii_stmt in
    `Assoc [
      ("call_sid", `Int ii_stmt.sid);
      ("call_loc", Ast_utils_ast.loc_to_json (Cil_datatype.Stmt.loc ii_stmt));
      ("source", `String "property-instance");
      ("called_property", clause_metadata_of_property ii_ip);
      ("contracts", `List contracts);
      ("unresolved", `List unresolved);
    ]
  | _ ->
    (match Property.get_kinstr prop with
     | Kstmt stmt ->
       let contracts, unresolved = callee_info_at_stmt stmt in
       `Assoc [
         ("source", `String "property-kinstr");
         ("contracts", `List contracts);
         ("unresolved", `List unresolved);
       ]
     | Kglobal ->
       `Assoc [
         ("source", `String "none");
         ("contracts", `List []);
         ("unresolved", `List []);
       ])

let vc_loc_json prop steps =
  let prop_loc = Property.location prop in
  if not (Ast_utils_compat.loc_is_unknown prop_loc) then
    (Ast_utils_ast.loc_to_json prop_loc, "high", "property")
  else
    match List.find_map (fun step ->
      match step.Wp.Conditions.stmt with
      | Some stmt -> Some (Cil_datatype.Stmt.loc stmt)
      | None -> None
    ) steps with
    | Some loc -> (Ast_utils_ast.loc_to_json loc, "low", "condition-statement")
    | None -> (`Null, "unknown", "unavailable")

(** Extract hypothesis kind string and structured metadata from a condition step. *)
let step_to_json (step : Wp.Conditions.step) : Json.t option =
  let make kind p =
    let stmt_fields =
      match step.stmt with
      | None -> []
      | Some stmt -> [
        ("sid", `Int stmt.sid);
        ("loc", Ast_utils_ast.loc_to_json (Cil_datatype.Stmt.loc stmt));
      ]
    in
    let descr_fields =
      match step.descr with
      | None -> []
      | Some descr -> [("description", `String descr)]
    in
    Some (`Assoc ([
      ("kind", `String kind);
      ("id", `Int step.id);
      ("size", `Int step.size);
      ("dep_count", `Int (List.length step.deps));
      ("formula", `String (pp_pred_to_string p))
    ] @ stmt_fields @ descr_fields))
  in
  match step.condition with
  | Wp.Conditions.Have p -> make "have" p
  | Wp.Conditions.When p -> make "when" p
  | Wp.Conditions.Type p -> make "type" p
  | Wp.Conditions.Init p -> make "init" p
  | Wp.Conditions.Core p -> make "core" p
  | Wp.Conditions.Branch (p, _, _) -> make "branch" p
  | Wp.Conditions.Either _ | Wp.Conditions.State _
  | Wp.Conditions.Probe _ -> None
