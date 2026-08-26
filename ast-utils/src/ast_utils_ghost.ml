(** ast_utils_ghost.ml — Ghost statement insertion/removal via direct CIL construction.

    Provides:
    - Type name resolution (string → CIL typ)
    - Simple C expression parser (recursive descent)
    - Ghost variable declaration insertion
    - Ghost assignment insertion
    - Ghost global variable insertion/removal
    - Ghost statement/variable removal with registry tracking

    All inserted statements have stmt.ghost = true and target variables
    have vghost = true, ensuring soundness (no effect on program semantics). *)

open Frama_c_kernel
open Cil_types

(* ====== Ghost Registry ====== *)

(* key: (function_name, var_name), value: sids of statements we inserted *)
let ghost_registry : (string * string, int list) Hashtbl.t =
  Hashtbl.create 16

(* key: function_name, value: statement-only ghost insert sids *)
let ghost_stmt_registry : (string, int list) Hashtbl.t =
  Hashtbl.create 16

let ghost_global_registry : (string, varinfo) Hashtbl.t =
  Hashtbl.create 16

let is_valid_c_identifier name =
  let len = String.length name in
  len > 0 &&
  (let c = name.[0] in
   (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_') &&
  (let ok = ref true in
   for i = 1 to len - 1 do
     let c = name.[i] in
     ok := !ok &&
       ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') || c = '_')
   done;
   !ok)

let is_reserved_logic_label = function
  | "Pre" | "Here" | "Old" | "Post" | "LoopEntry" | "LoopCurrent" -> true
  | _ -> false

(* ====== Type Resolution ====== *)

let rec split_pointer_type name depth =
  let name = String.trim name in
  let len = String.length name in
  if len > 0 && name.[len - 1] = '*' then
    split_pointer_type (String.sub name 0 (len - 1)) (depth + 1)
  else
    name, depth

let starts_with s prefix =
  let plen = String.length prefix in
  String.length s >= plen && String.sub s 0 plen = prefix

let rec pointer_wrap typ depth =
  if depth = 0 then typ
  else pointer_wrap (Cil_const.mk_tptr typ) (depth - 1)

let resolve_base_ghost_type name =
  match String.trim name with
  | "int" -> Ok Cil_const.intType
  | "unsigned int" | "unsigned" -> Ok Cil_const.uintType
  | "long" -> Ok Cil_const.longType
  | "unsigned long" -> Ok Cil_const.ulongType
  | "long long" -> Ok Cil_const.longLongType
  | "unsigned long long" -> Ok Cil_const.ulongLongType
  | "char" -> Ok Cil_const.charType
  | "short" -> Ok Cil_const.shortType
  | "unsigned short" -> Ok Cil_const.ushortType
  | "float" -> Ok Cil_const.floatType
  | "double" -> Ok Cil_const.doubleType
  | name when starts_with name "struct " ->
    let tag = String.trim (String.sub name 7 (String.length name - 7)) in
    (try Ok (Globals.Types.find_type Logic_typing.Struct tag)
     with Not_found -> Error (Printf.sprintf "unknown struct '%s'" tag))
  | name when starts_with name "union " ->
    let tag = String.trim (String.sub name 6 (String.length name - 6)) in
    (try Ok (Globals.Types.find_type Logic_typing.Union tag)
     with Not_found -> Error (Printf.sprintf "unknown union '%s'" tag))
  | name when starts_with name "enum " ->
    let tag = String.trim (String.sub name 5 (String.length name - 5)) in
    (try Ok (Globals.Types.find_type Logic_typing.Enum tag)
     with Not_found -> Error (Printf.sprintf "unknown enum '%s'" tag))
  | name ->
    try Ok (Globals.Types.find_type Logic_typing.Typedef name)
    with Not_found ->
      Error (Printf.sprintf "unsupported type '%s'" name)

let resolve_ghost_type name =
  let base, pointer_depth = split_pointer_type name 0 in
  match resolve_base_ghost_type base with
  | Ok typ -> Ok (pointer_wrap typ pointer_depth)
  | Error _ when pointer_depth > 0 ->
    Error (Printf.sprintf "unsupported type '%s'" name)
  | Error msg -> Error msg

(* ====== Expression Parser ====== *)

type token =
  | TkInt of int
  | TkIdent of string
  | TkPlus | TkMinus | TkStar | TkSlash | TkPercent
  | TkLBracket | TkRBracket | TkLParen | TkRParen
  | TkEof

type lexer_state = {
  input : string;
  len : int;
  mutable pos : int;
}

let mk_lexer s = { input = s; len = String.length s; pos = 0 }

let skip_ws ls =
  while ls.pos < ls.len &&
        let c = ls.input.[ls.pos] in
        c = ' ' || c = '\t' || c = '\n' || c = '\r' do
    ls.pos <- ls.pos + 1
  done

let is_digit c = c >= '0' && c <= '9'
let is_alpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'
let is_alnum c = is_digit c || is_alpha c

let next_token ls =
  skip_ws ls;
  if ls.pos >= ls.len then TkEof
  else
    let c = ls.input.[ls.pos] in
    match c with
    | '+' -> ls.pos <- ls.pos + 1; TkPlus
    | '-' -> ls.pos <- ls.pos + 1; TkMinus
    | '*' -> ls.pos <- ls.pos + 1; TkStar
    | '/' -> ls.pos <- ls.pos + 1; TkSlash
    | '%' -> ls.pos <- ls.pos + 1; TkPercent
    | '[' -> ls.pos <- ls.pos + 1; TkLBracket
    | ']' -> ls.pos <- ls.pos + 1; TkRBracket
    | '(' -> ls.pos <- ls.pos + 1; TkLParen
    | ')' -> ls.pos <- ls.pos + 1; TkRParen
    | _ when is_digit c ->
      let start = ls.pos in
      while ls.pos < ls.len && is_digit ls.input.[ls.pos] do
        ls.pos <- ls.pos + 1
      done;
      TkInt (int_of_string (String.sub ls.input start (ls.pos - start)))
    | _ when is_alpha c ->
      let start = ls.pos in
      while ls.pos < ls.len && is_alnum ls.input.[ls.pos] do
        ls.pos <- ls.pos + 1
      done;
      TkIdent (String.sub ls.input start (ls.pos - start))
    | _ ->
      failwith (Printf.sprintf
        "parse error: unexpected '%c' at position %d" c ls.pos)

let peek ls =
  let saved = ls.pos in
  let tok = next_token ls in
  ls.pos <- saved;
  tok

let find_var_in_fundec fundec name =
  try List.find (fun vi -> vi.vname = name) fundec.slocals
  with Not_found ->
  try List.find (fun vi -> vi.vname = name) fundec.sformals
  with Not_found ->
  try Globals.Vars.find_from_astinfo name Global
  with Not_found ->
    failwith (Printf.sprintf "unknown variable '%s'" name)

let rec parse_expr_impl ls fundec loc =
  parse_additive ls fundec loc

and parse_additive ls fundec loc =
  let left = ref (parse_multiplicative ls fundec loc) in
  let cont = ref true in
  while !cont do
    match peek ls with
    | TkPlus ->
      ignore (next_token ls);
      left := Ast_utils_compat.mk_binop ~loc PlusA !left
                (parse_multiplicative ls fundec loc)
    | TkMinus ->
      ignore (next_token ls);
      left := Ast_utils_compat.mk_binop ~loc MinusA !left
                (parse_multiplicative ls fundec loc)
    | _ -> cont := false
  done;
  !left

and parse_multiplicative ls fundec loc =
  let left = ref (parse_unary ls fundec loc) in
  let cont = ref true in
  while !cont do
    match peek ls with
    | TkStar ->
      ignore (next_token ls);
      left := Ast_utils_compat.mk_binop ~loc Mult !left
                (parse_unary ls fundec loc)
    | TkSlash ->
      ignore (next_token ls);
      left := Ast_utils_compat.mk_binop ~loc Div !left
                (parse_unary ls fundec loc)
    | TkPercent ->
      ignore (next_token ls);
      left := Ast_utils_compat.mk_binop ~loc Mod !left
                (parse_unary ls fundec loc)
    | _ -> cont := false
  done;
  !left

and parse_unary ls fundec loc =
  match peek ls with
  | TkMinus ->
    ignore (next_token ls);
    let e = parse_unary ls fundec loc in
    Cil.new_exp ~loc (UnOp (Neg, e, Cil.typeOf e))
  | _ -> parse_primary ls fundec loc

and parse_primary ls fundec loc =
  match next_token ls with
  | TkInt n ->
    Cil.integer ~loc n
  | TkIdent name ->
    let vi = find_var_in_fundec fundec name in
    (match peek ls with
     | TkLBracket ->
       ignore (next_token ls);
       let idx = parse_expr_impl ls fundec loc in
       (match next_token ls with
        | TkRBracket -> ()
        | _ -> failwith (Printf.sprintf
                 "parse error: expected ']' at position %d" ls.pos));
       (match Ast_types.unroll_node vi.vtype with
        | TArray _ ->
          Cil.new_exp ~loc (Lval (Var vi, Index (idx, NoOffset)))
        | TPtr _ ->
          let addr = Ast_utils_compat.mk_binop ~loc PlusPI (Cil.evar ~loc vi) idx in
          Cil.new_exp ~loc (Lval (Cil.mkMem ~addr ~off:NoOffset))
        | _ ->
          failwith (Printf.sprintf
            "variable '%s' is not an array or pointer" name))
     | _ ->
       Cil.evar ~loc vi)
  | TkLParen ->
    let e = parse_expr_impl ls fundec loc in
    (match next_token ls with
     | TkRParen -> ()
     | _ -> failwith (Printf.sprintf
              "parse error: expected ')' at position %d" ls.pos));
    e
  | TkEof ->
    failwith "parse error: unexpected end of input"
  | _ ->
    failwith (Printf.sprintf
      "parse error: unexpected token at position %d" ls.pos)

let parse_c_expr fundec loc expr_string =
  if String.length (String.trim expr_string) = 0 then
    Error "empty expression"
  else
    try
      let ls = mk_lexer expr_string in
      let e = parse_expr_impl ls fundec loc in
      (match peek ls with
       | TkEof -> Ok e
       | _ -> Error (Printf.sprintf
                "parse error: unexpected token at position %d" ls.pos))
    with Failure msg -> Error msg

let parse_global_init loc typ expr_string =
  let expr_string = String.trim expr_string in
  if expr_string = "" then Ok None
  else
    try
      let exp = Cil.integer ~loc (int_of_string expr_string) in
      let cast_exp =
        let exp_typ = Cil.typeOf exp in
        if Cil_datatype.Typ.equal exp_typ typ then exp
        else Cil.mkCast ~newt:typ exp
      in
      Ok (Some (CInit (SingleInit cast_exp)))
    with Failure _ ->
      Error "ghost global initializer must be an integer literal"

(* ====== Internal Helpers ====== *)

let rebuild_cfg fundec =
  Cfg.clearCFGinfo ~clear_id:false fundec;
  Cfg.cfgFun fundec

(* Insert new_stmt before target_sid in the function body (recursive) *)
let rec insert_in_block target_sid new_stmt b =
  let found = ref false in
  let new_bstmts = List.fold_right (fun s acc ->
    if s.sid = target_sid then begin
      found := true;
      new_stmt :: s :: acc
    end else begin
      insert_in_skind target_sid new_stmt s.skind;
      s :: acc
    end
  ) b.bstmts [] in
  if !found then b.bstmts <- new_bstmts;
  !found

and insert_in_skind target_sid new_stmt = function
  | If (_, tb, fb, _) ->
    ignore (insert_in_block target_sid new_stmt tb);
    ignore (insert_in_block target_sid new_stmt fb)
  | Loop (_, b, _, _, _) | Block b ->
    ignore (insert_in_block target_sid new_stmt b)
  | Switch (_, b, _, _) ->
    ignore (insert_in_block target_sid new_stmt b)
  | _ -> ()

(* Remove statements by sid list from the function body (recursive) *)
let rec remove_from_block sids b =
  b.bstmts <- List.filter (fun s -> not (List.mem s.sid sids)) b.bstmts;
  List.iter (fun s -> remove_from_skind sids s.skind) b.bstmts

and remove_from_skind sids = function
  | If (_, tb, fb, _) ->
    remove_from_block sids tb;
    remove_from_block sids fb
  | Loop (_, b, _, _, _) | Block b ->
    remove_from_block sids b
  | Switch (_, b, _, _) ->
    remove_from_block sids b
  | _ -> ()

let rec collect_stmt_tree acc stmt =
  let acc = stmt :: acc in
  match stmt.skind with
  | If (_, tb, fb, _) ->
    collect_block_tree (collect_block_tree acc tb) fb
  | Loop (_, b, _, _, _) | Block b | Switch (_, b, _, _) ->
    collect_block_tree acc b
  | UnspecifiedSequence seq ->
    List.fold_left (fun acc (s, _, _, _, _) -> collect_stmt_tree acc s) acc seq
  | _ -> acc

and collect_block_tree acc block =
  List.fold_left collect_stmt_tree acc block.bstmts

let rec force_stmt_ghost stmt =
  stmt.ghost <- true;
  match stmt.skind with
  | If (_, tb, fb, _) ->
    force_block_ghost tb;
    force_block_ghost fb
  | Loop (_, b, _, _, _) | Block b | Switch (_, b, _, _) ->
    force_block_ghost b
  | UnspecifiedSequence seq ->
    List.iter (fun (s, _, _, _, _) -> force_stmt_ghost s) seq
  | _ -> ()

and force_block_ghost block =
  List.iter force_stmt_ghost block.bstmts

(* ====== Public API ====== *)

let insert_ghost_global name typ init =
  try
    if not (is_valid_c_identifier name) then
      Error (Printf.sprintf "invalid global name '%s'" name)
    else begin
      (try
         let _ = Globals.Vars.find_from_astinfo name Global in
         raise (Failure (Printf.sprintf "global '%s' already exists" name))
       with Not_found -> ());
      let loc = Ast_utils_compat.loc_unknown in
      let vi = Cil.makeGlobalVar ~ghost:true ~temp:false ~loc name typ in
      vi.vdefined <- true;
      let initinfo = { init } in
      let global = GVar (vi, initinfo, loc) in
      let file = Ast.get () in
      file.globals <- file.globals @ [global];
      Globals.Vars.add vi initinfo;
      Hashtbl.replace ghost_global_registry name vi;
      Ast.mark_as_changed ();
      Ok vi
    end
  with
  | Failure msg -> Error msg
  | Globals.Vars.AlreadyExists _ ->
    Error (Printf.sprintf "global '%s' already exists" name)
  | exn -> Error (Printexc.to_string exn)

let insert_ghost_lemma_function
    name param_name param_typ requires decreases assigns ensures =
  try
    if not (is_valid_c_identifier name) then
      Error (Printf.sprintf "invalid function name '%s'" name)
    else if not (is_valid_c_identifier param_name) then
      Error (Printf.sprintf "invalid parameter name '%s'" param_name)
    else begin
      (try
         ignore (Globals.Functions.find_by_name name);
         raise (Failure (Printf.sprintf "function '%s' already exists" name))
       with Not_found -> ());
      (try
         ignore (Globals.Vars.find_from_astinfo name Global);
         raise (Failure (Printf.sprintf "global '%s' already exists" name))
       with Not_found -> ());
      let loc = Ast_utils_compat.loc_unknown in
      let fun_typ =
        Cil_const.mk_tfun Cil_const.voidType
          (Some [(param_name, param_typ, [])]) false
      in
      let vi = Cil.makeGlobalVar ~ghost:true ~temp:false ~loc name fun_typ in
      vi.vdefined <- true;
      let fundec = Cil.emptyFunctionFromVI vi in
      let param = Cil.makeFormalVar fundec param_name param_typ in
      Cil.setFormals fundec [param];
      let recursive_arg =
        Ast_utils_compat.mk_binop ~loc MinusA (Cil.evar ~loc param) (Cil.integer ~loc 1)
      in
      let call_stmt =
        Cil.mkStmtOneInstr ~ghost:true ~valid_sid:true
          (Call (None, Var vi, [recursive_arg], loc))
      in
      let guard =
        Cil.new_exp ~loc
          (BinOp (Gt, Cil.evar ~loc param, Cil.integer ~loc 0,
                  Cil_const.intType))
      in
      let if_stmt =
        Cil.mkStmt ~ghost:true ~valid_sid:true
          (If (guard, Cil.mkBlock [call_stmt], Cil.mkBlock [], loc))
      in
      let return_stmt =
        Cil.mkStmt ~ghost:true ~valid_sid:true (Return (None, loc))
      in
      fundec.sbody <- Cil.mkBlock [if_stmt; return_stmt];
      fundec.sallstmts <- collect_block_tree [] fundec.sbody;
      rebuild_cfg fundec;
      let file = Ast.get () in
      file.globals <- file.globals @ [GFun (fundec, loc)];
      Globals.Functions.add (Definition (fundec, loc));
      let kf = Globals.Functions.get vi in
      (try Populate_spec.populate_funspec kf [`Assigns] with _ -> ());
      let rollback msg =
        file.globals <- List.filter (function
          | GFun ({ svar = gv; _ }, _) when gv.vid = vi.vid -> false
          | GFunDecl (_, gv, _) when gv.vid = vi.vid -> false
          | _ -> true) file.globals;
        (try Globals.Functions.remove vi with _ -> ());
        Error msg
      in
      let contract =
        Printf.sprintf "requires %s; decreases %s; assigns %s; ensures %s;"
          requires decreases assigns ensures
      in
      match Ast_utils_core.type_spec kf contract with
      | Error msg -> rollback msg
      | Ok spec ->
        match Ast_utils_core.insert_spec kf spec with
        | Error msg -> rollback msg
        | Ok () ->
          (try Populate_spec.populate_funspec kf [`Assigns] with _ -> ());
          Ast.mark_as_changed ();
          Ok vi
    end
  with
  | Failure msg -> Error msg
  | exn -> Error (Printexc.to_string exn)

let insert_ghost_formal kf name typ where =
  try
    if not (is_valid_c_identifier name) then
      Error (Printf.sprintf "invalid formal name '%s'" name)
    else
      let fundec = Kernel_function.get_definition kf in
      let exists =
        List.exists (fun vi -> vi.vname = name) fundec.sformals ||
        List.exists (fun vi -> vi.vname = name) fundec.slocals
      in
      if exists then
        Error (Printf.sprintf "variable '%s' already exists" name)
      else begin
        let vi = Cil.makeFormalVar ~ghost:true ~where fundec name typ in
        Ast.mark_as_changed ();
        Ok vi
      end
  with
  | Kernel_function.No_Definition ->
    Error (Printf.sprintf "function '%s' has no definition"
             (Kernel_function.get_name kf))
  | Failure msg -> Error msg
  | exn -> Error (Printexc.to_string exn)

let insert_ghost_decl kf stmt var_name typ init_exp =
  try
    let fundec = Kernel_function.get_definition kf in
    let kf_name = Kernel_function.get_name kf in
    (* Check for duplicate variable name *)
    let exists_in_locals =
      List.exists (fun vi -> vi.vname = var_name) fundec.slocals in
    let exists_in_formals =
      List.exists (fun vi -> vi.vname = var_name) fundec.sformals in
    if exists_in_locals || exists_in_formals then
      Error (Printf.sprintf "variable '%s' already exists" var_name)
    else begin
      let loc = Cil_datatype.Stmt.loc stmt in
      (* Type compatibility check + implicit cast *)
      let cast_exp =
        let exp_typ = Cil.typeOf init_exp in
        if Cil_datatype.Typ.equal exp_typ typ then init_exp
        else Cil.mkCast ~newt:typ init_exp
      in
      (* Create ghost local variable (insert:false = don't auto-add) *)
      let vi = Cil.makeLocalVar ~insert:false ~ghost:true ~loc
                 fundec var_name typ in
      (* Manually add to slocals *)
      fundec.slocals <- fundec.slocals @ [vi];
      (* Build Local_init instruction *)
      let init_instr =
        Local_init (vi, AssignInit (SingleInit cast_exp), loc) in
      let new_stmt =
        Cil.mkStmtOneInstr ~ghost:true ~valid_sid:true init_instr in
      (* Insert before target stmt *)
      let inserted = insert_in_block stmt.sid new_stmt fundec.sbody in
      if not inserted then
        Error (Printf.sprintf "statement %d not found in function body"
                 stmt.sid)
      else begin
        fundec.sallstmts <- new_stmt :: fundec.sallstmts;
        rebuild_cfg fundec;
        (* Update registry *)
        Hashtbl.replace ghost_registry
          (kf_name, var_name) [new_stmt.sid];
        Ok new_stmt
      end
    end
  with
  | Kernel_function.No_Definition ->
    Error (Printf.sprintf "function '%s' has no definition"
             (Kernel_function.get_name kf))
  | Failure msg -> Error msg
  | exn -> Error (Printexc.to_string exn)

let insert_ghost_assign kf stmt target_name expr =
  try
    let fundec = Kernel_function.get_definition kf in
    let kf_name = Kernel_function.get_name kf in
    (* Find the target ghost variable *)
    let vi =
      try List.find (fun vi -> vi.vname = target_name) fundec.slocals
      with Not_found ->
        failwith (Printf.sprintf "variable '%s' not found" target_name)
    in
    if not vi.vghost then
      failwith (Printf.sprintf
        "variable '%s' is not a ghost variable" target_name);
    let loc = Cil_datatype.Stmt.loc stmt in
    (* Type compatibility check + implicit cast *)
    let cast_exp =
      let exp_typ = Cil.typeOf expr in
      if Cil_datatype.Typ.equal exp_typ vi.vtype then expr
      else Cil.mkCast ~newt:vi.vtype expr
    in
    (* Build Set instruction *)
    let set_instr = Set ((Var vi, NoOffset), cast_exp, loc) in
    let new_stmt =
      Cil.mkStmtOneInstr ~ghost:true ~valid_sid:true set_instr in
    (* Insert before target stmt *)
    let inserted = insert_in_block stmt.sid new_stmt fundec.sbody in
    if not inserted then
      Error (Printf.sprintf "statement %d not found in function body"
               stmt.sid)
    else begin
      fundec.sallstmts <- new_stmt :: fundec.sallstmts;
      rebuild_cfg fundec;
      (* Update registry *)
      let key = (kf_name, target_name) in
      let existing =
        try Hashtbl.find ghost_registry key
        with Not_found -> [] in
      Hashtbl.replace ghost_registry key (new_stmt.sid :: existing);
      Ok new_stmt
    end
  with
  | Kernel_function.No_Definition ->
    Error (Printf.sprintf "function '%s' has no definition"
             (Kernel_function.get_name kf))
  | Failure msg -> Error msg
  | exn -> Error (Printexc.to_string exn)

let insert_ghost_else_assign kf if_stmt target_name expr =
  try
    let fundec = Kernel_function.get_definition kf in
    let kf_name = Kernel_function.get_name kf in
    let vi =
      try List.find (fun vi -> vi.vname = target_name) fundec.slocals
      with Not_found ->
        failwith (Printf.sprintf "variable '%s' not found" target_name)
    in
    if not vi.vghost then
      failwith (Printf.sprintf
        "variable '%s' is not a ghost variable" target_name);
    match if_stmt.skind with
    | If (_, _, false_block, loc) ->
      if false_block.bstmts <> [] then
        Error "else_set requires an if statement with an empty else branch"
      else begin
        let cast_exp =
          let exp_typ = Cil.typeOf expr in
          if Cil_datatype.Typ.equal exp_typ vi.vtype then expr
          else Cil.mkCast ~newt:vi.vtype expr
        in
        let set_instr = Set ((Var vi, NoOffset), cast_exp, loc) in
        let new_stmt =
          Cil.mkStmtOneInstr ~ghost:true ~valid_sid:true set_instr in
        false_block.bstmts <- [new_stmt];
        fundec.sallstmts <- new_stmt :: fundec.sallstmts;
        rebuild_cfg fundec;
        let key = (kf_name, target_name) in
        let existing =
          try Hashtbl.find ghost_registry key
          with Not_found -> [] in
        Hashtbl.replace ghost_registry key (new_stmt.sid :: existing);
        Ok new_stmt
      end
    | _ ->
      Error "else_set target statement must be an if"
  with
  | Kernel_function.No_Definition ->
    Error (Printf.sprintf "function '%s' has no definition"
             (Kernel_function.get_name kf))
  | Failure msg -> Error msg
  | exn -> Error (Printexc.to_string exn)

let insert_ghost_loop
    kf stmt var_name typ init_exp stop_exp step_exp invariant assigns variant assert_pred =
  try
    let fundec = Kernel_function.get_definition kf in
    let kf_name = Kernel_function.get_name kf in
    let exists =
      List.exists (fun vi -> vi.vname = var_name) fundec.slocals ||
      List.exists (fun vi -> vi.vname = var_name) fundec.sformals
    in
    if not (is_valid_c_identifier var_name) then
      Error (Printf.sprintf "invalid loop variable name '%s'" var_name)
    else if exists then
      Error (Printf.sprintf "variable '%s' already exists" var_name)
    else begin
      let loc = Cil_datatype.Stmt.loc stmt in
      let vi =
        Cil.makeLocalVar ~insert:false ~ghost:true ~loc fundec var_name typ in
      fundec.slocals <- fundec.slocals @ [vi];
      let cast_to_counter exp =
        if Cil_datatype.Typ.equal (Cil.typeOf exp) typ then exp
        else Cil.mkCast ~newt:typ exp
      in
      let init_stmt =
        Cil.mkStmtOneInstr ~ghost:true ~valid_sid:true
          (Local_init (vi, AssignInit (SingleInit (cast_to_counter init_exp)), loc))
      in
      let stop = cast_to_counter stop_exp in
      let step = cast_to_counter step_exp in
      let next =
        Cil.mkStmtOneInstr ~ghost:true ~valid_sid:true
          (Set
             (Cil.var vi,
              Ast_utils_compat.mk_binop ~loc PlusA (Cil.evar ~loc vi) step,
              loc))
      in
      let loop_stmts =
        Cil.mkFor
          ~start:[]
          ~guard:(Cil.new_exp ~loc (BinOp (Lt, Cil.evar ~loc vi, stop, Cil_const.intType)))
          ~next:[next]
          ~body:[]
          ()
      in
      List.iter force_stmt_ghost loop_stmts;
      let loop_stmt =
        match List.rev loop_stmts with
        | loop_stmt :: _ -> loop_stmt
        | [] -> failwith "failed to build ghost loop"
      in
      let stmts = ref (init_stmt :: loop_stmts) in
      let post_assert = ref None in
      (match String.trim assert_pred with
       | "" -> ()
       | pred ->
         let stmt = Cil.mkEmptyStmt ~ghost:true ~valid_sid:true ~loc () in
         post_assert := Some (stmt, pred);
         stmts := !stmts @ [stmt]);
      let block = Cil.mkBlock !stmts in
      let block_stmt = Cil.mkStmt ~ghost:true ~valid_sid:true (Block block) in
      force_stmt_ghost block_stmt;
      let inserted = insert_in_block stmt.sid block_stmt fundec.sbody in
      if not inserted then begin
        fundec.slocals <- List.filter (fun v -> v.vid <> vi.vid) fundec.slocals;
        Error (Printf.sprintf "statement %d not found in function body" stmt.sid)
      end
      else begin
        let inserted_sids =
          collect_stmt_tree [] block_stmt |> List.map (fun s -> s.sid) in
        fundec.sallstmts <- collect_stmt_tree [] block_stmt @ fundec.sallstmts;
        rebuild_cfg fundec;
        let rollback msg =
          remove_from_block [block_stmt.sid] fundec.sbody;
          fundec.sallstmts <-
            List.filter (fun s -> not (List.mem s.sid inserted_sids))
              fundec.sallstmts;
          fundec.slocals <-
            List.filter (fun v -> v.vid <> vi.vid) fundec.slocals;
          rebuild_cfg fundec;
          Error msg
        in
        let loop_acsl =
          Printf.sprintf "loop invariant %s; loop assigns %s; loop variant %s;"
            invariant assigns variant
        in
        match Ast_utils_core.type_annot kf loop_stmt loop_acsl with
        | Error msg -> rollback msg
        | Ok loop_annots ->
          let assert_annots =
            match !post_assert with
            | None -> Ok []
            | Some (stmt, pred) ->
              Ast_utils_core.type_annot kf stmt (Printf.sprintf "assert %s;" pred)
          in
          match assert_annots with
          | Error msg -> rollback msg
          | Ok assert_annots ->
            Ast_utils_core.insert_annots kf loop_stmt loop_annots;
            (match !post_assert with
             | None -> ()
             | Some (stmt, _) ->
               Ast_utils_core.insert_annots kf stmt assert_annots);
            Hashtbl.replace ghost_registry (kf_name, var_name) inserted_sids;
            Ast.mark_as_changed ();
            Ok (block_stmt, loop_stmt, vi, inserted_sids)
      end
    end
  with
  | Kernel_function.No_Definition ->
    Error (Printf.sprintf "function '%s' has no definition"
             (Kernel_function.get_name kf))
  | Failure msg -> Error msg
  | exn -> Error (Printexc.to_string exn)

let insert_ghost_label kf stmt label_name =
  try
    let fundec = Kernel_function.get_definition kf in
    let kf_name = Kernel_function.get_name kf in
    if not (is_valid_c_identifier label_name) then
      Error (Printf.sprintf "invalid label name '%s'" label_name)
    else if is_reserved_logic_label label_name then
      Error (Printf.sprintf "reserved logic label '%s'" label_name)
    else if Datatype.String.Set.mem label_name
              (Kernel_function.find_all_labels kf) then
      Error (Printf.sprintf "label '%s' already exists" label_name)
    else begin
      let loc = Cil_datatype.Stmt.loc stmt in
      let new_stmt = Cil.mkEmptyStmt ~ghost:true ~valid_sid:true ~loc () in
      new_stmt.labels <- [Label (label_name, loc, true)];
      let inserted = insert_in_block stmt.sid new_stmt fundec.sbody in
      if not inserted then
        Error (Printf.sprintf "statement %d not found in function body"
                 stmt.sid)
      else begin
        fundec.sallstmts <- new_stmt :: fundec.sallstmts;
        rebuild_cfg fundec;
        let existing =
          try Hashtbl.find ghost_stmt_registry kf_name
          with Not_found -> [] in
        Hashtbl.replace ghost_stmt_registry kf_name (new_stmt.sid :: existing);
        Ok new_stmt
      end
    end
  with
  | Kernel_function.No_Definition ->
    Error (Printf.sprintf "function '%s' has no definition"
             (Kernel_function.get_name kf))
  | Failure msg -> Error msg
  | exn -> Error (Printexc.to_string exn)
