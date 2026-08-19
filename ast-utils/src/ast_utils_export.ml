(** ast_utils_export.ml — F-CIL JSON exporter.

    Converts Frama-C CIL AST to F-CIL JSON format for consumption by
    the fv-core Rust library. *)

open Frama_c_kernel
open Cil_types

(* ====== §2: Ident allocation ====== *)

type ident_table = {
  names: (int, string) Hashtbl.t;
  enum_cache: (string, int) Hashtbl.t;
  field_cache: (int * string, int) Hashtbl.t;
  typedef_cache: (string, int) Hashtbl.t;
  goto_label_cache: (string, int) Hashtbl.t;
  mutable enum_counter: int;
  mutable field_counter: int;
  mutable typedef_counter: int;
  mutable goto_label_counter: int;
  mutable synth_stmt_counter: int;
}

let create_ident_table () = {
  names = Hashtbl.create 256;
  enum_cache = Hashtbl.create 32;
  field_cache = Hashtbl.create 64;
  typedef_cache = Hashtbl.create 32;
  goto_label_cache = Hashtbl.create 16;
  enum_counter = 0;
  field_counter = 0;
  typedef_counter = 0;
  goto_label_counter = 0;
  synth_stmt_counter = 0;
}

let var_id tbl (vi : varinfo) =
  Hashtbl.replace tbl.names vi.vid vi.vname;
  vi.vid

let comp_id tbl (ci : compinfo) =
  let id = 1_000_000 + ci.ckey in
  Hashtbl.replace tbl.names id ci.cname;
  id

let enum_id tbl (ei : enuminfo) =
  match Hashtbl.find_opt tbl.enum_cache ei.ename with
  | Some id -> id
  | None ->
    let id = 2_000_000 + tbl.enum_counter in
    tbl.enum_counter <- tbl.enum_counter + 1;
    Hashtbl.replace tbl.enum_cache ei.ename id;
    Hashtbl.replace tbl.names id ei.ename;
    id

let field_id tbl (fi : fieldinfo) =
  let key = (fi.fcomp.ckey, fi.fname) in
  match Hashtbl.find_opt tbl.field_cache key with
  | Some id -> id
  | None ->
    let id = 3_000_000 + tbl.field_counter in
    tbl.field_counter <- tbl.field_counter + 1;
    Hashtbl.replace tbl.field_cache key id;
    Hashtbl.replace tbl.names id fi.fname;
    id

let typedef_id tbl (ti : typeinfo) =
  match Hashtbl.find_opt tbl.typedef_cache ti.tname with
  | Some id -> id
  | None ->
    let id = 4_000_000 + tbl.typedef_counter in
    tbl.typedef_counter <- tbl.typedef_counter + 1;
    Hashtbl.replace tbl.typedef_cache ti.tname id;
    Hashtbl.replace tbl.names id ti.tname;
    id

let goto_label_id tbl (name : string) =
  match Hashtbl.find_opt tbl.goto_label_cache name with
  | Some id -> id
  | None ->
    let id = 5_000_000 + tbl.goto_label_counter in
    tbl.goto_label_counter <- tbl.goto_label_counter + 1;
    Hashtbl.replace tbl.goto_label_cache name id;
    Hashtbl.replace tbl.names id name;
    id

let synth_stmt_id tbl =
  let id = 6_000_000 + tbl.synth_stmt_counter in
  tbl.synth_stmt_counter <- tbl.synth_stmt_counter + 1;
  id

let ident_names_to_json tbl : Yojson.Basic.t =
  let pairs = Hashtbl.fold (fun id name acc ->
    (string_of_int id, `String name) :: acc
  ) tbl.names [] in
  `Assoc pairs

(* ====== JSON constructors ====== *)

let mk_kind tag fields : Yojson.Basic.t =
  `Assoc (("tag", `String tag) :: fields)

let loc_to_json (loc : Cil_types.location) : Yojson.Basic.t =
  let pos = fst loc in
  `Assoc [
    ("file", `String (Filepath.to_string (Filepos.path pos)));
    ("line", `Int (Filepos.line pos));
    ("col", `Int (Filepos.input_column pos));
  ]

let stmt_loc_to_json (s : stmt) : Yojson.Basic.t =
  let loc = Cil_datatype.Stmt.loc s in
  if Fileloc.equal loc Fileloc.unknown
  then `Null
  else loc_to_json loc

let mk_stmt_json ?(succs=[]) ?(preds=[]) si_id loc_json labels_json kind_json : Yojson.Basic.t =
  let fields = [("si_id", `Int si_id); ("kind", kind_json)] in
  let fields = match succs with
    | [] -> fields
    | _ -> ("_debug_succs", `List (List.map (fun s -> `Int s) succs)) :: fields in
  let fields = match preds with
    | [] -> fields
    | _ -> ("_debug_preds", `List (List.map (fun s -> `Int s) preds)) :: fields in
  let fields = match loc_json with
    | `Null -> fields
    | _ -> ("si_loc", loc_json) :: fields in
  let fields = match labels_json with
    | `List [] -> fields
    | _ -> ("si_labels", labels_json) :: fields in
  `Assoc fields

let mk_skip_stmt () =
  mk_stmt_json 0 `Null (`List []) (mk_kind "CilSskip" [])

(* ====== §3.1: Attributes ====== *)

let rec attrparam_to_json (ap : attrparam) : Yojson.Basic.t =
  match ap with
  | AInt n -> mk_kind "APint" [("n", `Int (Z.to_int n))]
  | AStr s -> mk_kind "APstr" [("s", `String s)]
  | ACons (name, args) ->
    mk_kind "APcons" [("name", `String name);
                       ("args", `List (List.map attrparam_to_json args))]
  | _ ->
    (* Fallback: pretty-print as APstr *)
    mk_kind "APstr" [("s", `String (Format.asprintf "%a" Printer.pp_attrparam ap))]

let cil_attr_to_json (attrs : attributes) : Yojson.Basic.t =
  let ca_const = ref false in
  let ca_volatile = ref false in
  let ca_restrict = ref false in
  let ca_alignas = ref None in
  let ca_attrs = ref [] in
  List.iter (fun (name, params) ->
    match name, params with
    | "const", [] -> ca_const := true
    | "volatile", [] -> ca_volatile := true
    | "restrict", [] -> ca_restrict := true
    | "_Alignas", [AInt n] ->
      ca_alignas := Some (Z.to_int n)
    | _ ->
      let param_jsons = List.map attrparam_to_json params in
      ca_attrs := (name, param_jsons) :: !ca_attrs
  ) attrs;
  (* Only output non-default fields *)
  let fields = ref [] in
  if !ca_attrs <> [] then
    fields := ("ca_attrs",
      `List (List.rev_map (fun (n, ps) ->
        `List [`String n; `List ps]
      ) !ca_attrs)) :: !fields;
  (match !ca_alignas with
   | Some n -> fields := ("ca_alignas", `Int n) :: !fields
   | None -> ());
  if !ca_restrict then fields := ("ca_restrict", `Bool true) :: !fields;
  if !ca_volatile then fields := ("ca_volatile", `Bool true) :: !fields;
  if !ca_const then fields := ("ca_const", `Bool true) :: !fields;
  `Assoc !fields

(* ====== §3.2: ikind/fkind mapping ====== *)

let ikind_to_string = function
  | IBool -> "CIbool"
  | IChar -> "CIchar" | ISChar -> "CIschar" | IUChar -> "CIuchar"
  | IInt -> "CIint" | IUInt -> "CIuint"
  | IShort -> "CIshort" | IUShort -> "CIushort"
  | ILong -> "CIlong" | IULong -> "CIulong"
  | ILongLong -> "CIlonglong" | IULongLong -> "CIulonglong"
  | IInt128 -> "CIint128" | IUInt128 -> "CIuint128"

let fkind_to_string = function
  | FFloat -> "CFfloat"
  | FDouble -> "CFdouble"
  | FLongDouble -> "CFlongdouble"
  | FFloat32 -> "CFfloat32" | FFloat64 -> "CFfloat64"

(* ====== §3.2: cil_type_to_json ====== *)

let rec cil_type_to_json tbl (t : typ) : Yojson.Basic.t =
  let attr = cil_attr_to_json t.tattr in
  match t.tnode with
  | TVoid ->
    mk_kind "CTvoid" []
  | TInt ik ->
    mk_kind "CTint" [("ik", `String (ikind_to_string ik)); ("attr", attr)]
  | TFloat fk ->
    mk_kind "CTfloat" [("fk", `String (fkind_to_string fk)); ("attr", attr)]
  | TPtr inner ->
    mk_kind "CTptr" [("inner", cil_type_to_json tbl inner); ("attr", attr)]
  | TArray (elem, size_opt) ->
    let size = match size_opt with
      | Some e ->
        (match Cil.constFoldToInt e with
         | Some n -> `Int (Z.to_int n)
         | None -> `Null)
      | None -> `Null in
    let fields = [("elem", cil_type_to_json tbl elem); ("attr", attr)] in
    let fields = if size <> `Null then ("size", size) :: fields else fields in
    mk_kind "CTarray" fields
  | TFun (ret, params_opt, va) ->
    let params = match params_opt with
      | None -> `Null
      | Some ps ->
        `List (List.map (fun (name, ty, pattr) ->
          let vi_id = goto_label_id tbl name in (* reuse label cache for param names *)
          Hashtbl.replace tbl.names vi_id name;
          `Assoc [("name", `Int vi_id);
                  ("ty", cil_type_to_json tbl ty);
                  ("attr", cil_attr_to_json pattr)]
        ) ps) in
    let fields = [("ret", cil_type_to_json tbl ret);
                  ("variadic", `Bool va); ("attr", attr)] in
    let fields = if params <> `Null then ("params", params) :: fields else fields in
    mk_kind "CTfun" fields
  | TComp ci ->
    let tag = if ci.cstruct then "CTstruct" else "CTunion" in
    mk_kind tag [("id", `Int (comp_id tbl ci)); ("attr", attr)]
  | TEnum ei ->
    mk_kind "CTenum" [("id", `Int (enum_id tbl ei));
                       ("ik", `String (ikind_to_string ei.ekind));
                       ("attr", attr)]
  | TNamed ti ->
    mk_kind "CTnamed" [("name", `Int (typedef_id tbl ti));
                        ("underlying", cil_type_to_json tbl ti.ttype);
                        ("attr", attr)]
  | TBuiltin_va_list ->
    mk_kind "CTbuiltin_va_list" [("attr", attr)]

(* ====== §3.3: cil_expr_to_json ====== *)

let unop_to_string = function
  | Neg -> "Oneg"
  | BNot -> "Onotint"
  | LNot -> "Onotbool"

let binop_to_json = function
  | PlusA -> mk_kind "CilBop" [("op", `String "Oadd")]
  | MinusA -> mk_kind "CilBop" [("op", `String "Osub")]
  | Mult -> mk_kind "CilBop" [("op", `String "Omul")]
  | Div -> mk_kind "CilBop" [("op", `String "Odiv")]
  | Mod -> mk_kind "CilBop" [("op", `String "Omod")]
  | BAnd -> mk_kind "CilBop" [("op", `String "Oand")]
  | BOr -> mk_kind "CilBop" [("op", `String "Oor")]
  | BXor -> mk_kind "CilBop" [("op", `String "Oxor")]
  | Shiftlt -> mk_kind "CilBop" [("op", `String "Oshl")]
  | Shiftrt -> mk_kind "CilBop" [("op", `String "Oshr")]
  | Eq -> mk_kind "CilBop" [("op", `String "Oeq")]
  | Ne -> mk_kind "CilBop" [("op", `String "One")]
  | Lt -> mk_kind "CilBop" [("op", `String "Olt")]
  | Gt -> mk_kind "CilBop" [("op", `String "Ogt")]
  | Le -> mk_kind "CilBop" [("op", `String "Ole")]
  | Ge -> mk_kind "CilBop" [("op", `String "Oge")]
  | PlusPI -> mk_kind "CilBop_PlusPI" []
  | MinusPI -> mk_kind "CilBop_MinusPI" []
  | MinusPP -> mk_kind "CilBop_MinusPP" []
  | LAnd | LOr -> assert false (* handled at expr level *)

let rec cil_expr_to_json tbl (e : exp) : Yojson.Basic.t =
  let ty = cil_type_to_json tbl (Cil.typeOf e) in
  match e.enode with
  | Const (CInt64 (i, ik, _)) ->
    if Cil.bytesSizeOfInt ik > 4 then
      (* 64-bit signed: modulo 2^64 and truncate to int64 *)
      let m = Z.logand i (Z.of_string "18446744073709551615") in
      let signed = if Z.gt m (Z.of_string "9223372036854775807")
                   then Z.sub m (Z.of_string "18446744073709551616")
                   else m in
      mk_kind "CilEconst_long" [("i", `String (Z.to_string signed)); ("ty", ty)]
    else
      (* 32-bit signed: take modulo 2^32 and truncate to int32 *)
      let m = Z.logand i (Z.of_int 0xFFFFFFFF) in
      let signed = if Z.gt m (Z.of_int 0x7FFFFFFF)
                   then Z.sub m (Z.add (Z.of_int 0xFFFFFFFF) Z.one)
                   else m in
      mk_kind "CilEconst_int" [("i", `Int (Z.to_int signed)); ("ty", ty)]
  | Const (CReal (f, FFloat, _)) ->
    mk_kind "CilEconst_single" [("f", `Float f); ("ty", ty)]
  | Const (CReal (f, _, _)) ->
    mk_kind "CilEconst_float" [("f", `Float f); ("ty", ty)]
  | Const (CChr c) ->
    mk_kind "CilEconst_int" [("i", `Int (Char.code c)); ("ty", ty)]
  | Const (CEnum {eival; eihost; _}) ->
    let enum_ty = cil_type_to_json tbl
      {tnode = TEnum eihost; tattr = []} in
    let value = match Cil.constFoldToInt eival with
      | Some n -> Z.to_int n | None -> 0 in
    mk_kind "CilEconst_int" [("i", `Int value); ("ty", enum_ty)]
  | Lval lv ->
    lval_to_expr_json tbl lv
  | SizeOf t ->
    mk_kind "CilEsizeof" [("sizeof_ty", cil_type_to_json tbl t); ("ty", ty)]
  | SizeOfE inner ->
    mk_kind "CilEsizeof" [("sizeof_ty", cil_type_to_json tbl (Cil.typeOf inner));
                           ("ty", ty)]
  | AlignOf (t, _) ->
    mk_kind "CilEalignof" [("alignof_ty", cil_type_to_json tbl t); ("ty", ty)]
  | AlignOfE (inner, _) ->
    mk_kind "CilEalignof" [("alignof_ty", cil_type_to_json tbl (Cil.typeOf inner));
                            ("ty", ty)]
  | UnOp (op, e1, _) ->
    mk_kind "CilEunop" [("op", `String (unop_to_string op));
                         ("e", cil_expr_to_json tbl e1); ("ty", ty)]
  | BinOp (LAnd, e1, e2, _) ->
    mk_kind "CilEand" [("e1", cil_expr_to_json tbl e1);
                        ("e2", cil_expr_to_json tbl e2); ("ty", ty)]
  | BinOp (LOr, e1, e2, _) ->
    mk_kind "CilEor" [("e1", cil_expr_to_json tbl e1);
                       ("e2", cil_expr_to_json tbl e2); ("ty", ty)]
  | BinOp (op, e1, e2, _) ->
    mk_kind "CilEbinop" [("op", binop_to_json op);
                          ("e1", cil_expr_to_json tbl e1);
                          ("e2", cil_expr_to_json tbl e2); ("ty", ty)]
  | CastE (t, e1) ->
    mk_kind "CilEcast" [("e", cil_expr_to_json tbl e1);
                         ("ty", cil_type_to_json tbl t)]
  | AddrOf lv ->
    mk_kind "CilEaddrof" [("e", lval_to_expr_json tbl lv); ("ty", ty)]
  | StartOf lv ->
    mk_kind "CilEaddrof" [("e", lval_to_expr_json tbl lv); ("ty", ty)]

(* §3.3.1: Lval → CilExpr *)
and lval_to_expr_json tbl ((host, offset) : lval) : Yojson.Basic.t =
  let base, base_ty = match host with
    | Var vi ->
      mk_kind "CilEvar" [("x", `Int (var_id tbl vi));
                          ("ty", cil_type_to_json tbl vi.vtype)],
      vi.vtype
    | Mem e ->
      let pointee_ty = Ast_types.direct_pointed_type (Cil.typeOf e) in
      mk_kind "CilEderef" [("e", cil_expr_to_json tbl e);
                            ("ty", cil_type_to_json tbl pointee_ty)],
      pointee_ty
  in
  apply_offset_json tbl base base_ty offset

and apply_offset_json tbl base base_ty = function
  | NoOffset -> base
  | Field (fi, rest) ->
    let fld = field_id tbl fi in
    let field_e = mk_kind "CilEfield"
      [("e", base); ("fld", `Int fld);
       ("ty", cil_type_to_json tbl fi.ftype)] in
    apply_offset_json tbl field_e fi.ftype rest
  | Index (idx, rest) ->
    let elem_ty = match (Ast_types.unroll base_ty).tnode with
      | TArray (t, _) -> t
      | TPtr t -> t
      | _ -> base_ty in
    let ptr_ty = {tnode = TPtr elem_ty; tattr = []} in
    let plus = mk_kind "CilEbinop"
      [("op", mk_kind "CilBop_PlusPI" []);
       ("e1", base); ("e2", cil_expr_to_json tbl idx);
       ("ty", cil_type_to_json tbl ptr_ty)] in
    let deref = mk_kind "CilEderef"
      [("e", plus); ("ty", cil_type_to_json tbl elem_ty)] in
    apply_offset_json tbl deref elem_ty rest

(* ====== §3.6: ACSL types ====== *)

let rec acsl_type_to_json tbl (lt : logic_type) : Yojson.Basic.t =
  match lt with
  | Ctype ty -> mk_kind "ACTYc_type" [("ty", cil_type_to_json tbl ty)]
  | Linteger -> mk_kind "ACTYlogic" [("name", `String "integer")]
  | Lreal -> mk_kind "ACTYlogic" [("name", `String "real")]
  | Ltype (lti, args) ->
    mk_kind "ACTYpoly" [("name", `String lti.lt_name);
                         ("args", `List (List.map (acsl_type_to_json tbl) args))]
  | Lvar v -> mk_kind "ACTYlogic" [("name", `String v)]
  | Larrow _ -> mk_kind "ACTYlogic" [("name", `String "arrow")]
  | Lboolean -> mk_kind "ACTYlogic" [("name", `String "boolean")]

(* ====== §3.6.2: ACSL term ====== *)

(* All AcslTerm ctors carry a `ty` field (result type). Source: Cil_types.term.term_type
   which is filled in by frama-c logic typer. The helper threads this ty into
   every mk_kind invocation. *)
let rec acsl_term_to_json tbl (t : term) : Yojson.Basic.t =
  let ty = acsl_type_to_json tbl t.term_type in
  let with_ty fields = fields @ [("ty", ty)] in
  let mk k fs = mk_kind k (with_ty fs) in
  (* Note: ATfield / ATsubscript via offset application use the parent term's ty
     as approximation (acsl_apply_offset / acsl_apply_toffset). frama-c CIL
     does not eagerly compute compound field types in our exporter; recovering
     it would require a separate offset-typing pass. closure scanner only uses
     ty for type-dep collection, so this approximation is acceptable. *)
  match t.term_node with
  | TConst (Integer (n, _)) ->
    mk "ATint_lit" [("n", `Int (Z.to_int n))]
  | TConst (LReal {r_literal; _}) ->
    mk "ATfloat_lit" [("s", `String r_literal)]
  | TConst (LStr s) ->
    mk "ATstring_lit" [("s", `String s)]
  | TConst (LWStr ws) ->
    let s = String.concat "" (List.map (fun i ->
      String.make 1 (Char.chr (Int64.to_int i))) ws) in
    mk "ATstring_lit" [("s", `String s)]
  | TConst (LChr c) ->
    mk "ATint_lit" [("n", `Int (Char.code c))]
  | TConst (LEnum {eival; _}) ->
    let value = match Cil.constFoldToInt eival with
      | Some n -> Z.to_int n | None -> 0 in
    mk "ATint_lit" [("n", `Int value)]
  | TLval (TVar lv, TNoOffset)
    when String.length lv.lv_name > 0 && lv.lv_name.[0] = '\\' ->
    (* Builtin logic constant (\pi / \e / \true / \false / \nothing / etc.).
       Emit as ATapp with empty args + func = lv_name; the printer treats
       \-prefixed empty-args ATapp as a constant (no parens). *)
    mk "ATapp" [("func", `String lv.lv_name); ("args", `List [])]
  | TLval (TVar lv, TNoOffset) ->
    mk "ATident" [("name", `Int lv.lv_id)]
  | TLval (TResult _, TNoOffset) ->
    mk "ATresult" []
  | TLval (TVar lv, TField (fi, rest)) ->
    (* M-5: The starting typ uses the CIL typ of lv (if the logical variable falls back to field type) *)
    let start_typ = match lv.lv_type with
      | Ctype t -> t
      | _ -> fi.ftype
    in
    let base = mk "ATident" [("name", `Int lv.lv_id)] in
    acsl_apply_offset tbl start_typ base rest fi
  | TLval (TVar lv, TIndex (idx, rest)) ->
    let start_typ = match lv.lv_type with
      | Ctype t -> t
      | _ -> Cil_const.intType (* fallback: Theoretically, logic var will not have array subscript access *)
    in
    let elem_typ = match (Ast_types.unroll start_typ).tnode with
      | TArray (t, _) -> t
      | TPtr t -> t
      | _ -> start_typ
    in
    let elem_ty_json = acsl_type_to_json tbl (Ctype elem_typ) in
    let base = mk "ATident" [("name", `Int lv.lv_id)] in
    let subscr = mk_kind "ATsubscript"
      [("t", base); ("idx", acsl_term_to_json tbl idx); ("ty", elem_ty_json)] in
    acsl_apply_toffset tbl elem_typ subscr rest
  | TLval (TMem t1, off) ->
    (* TMem is a pointer dereference, starting typ = pointee of pointer *)
    let pointee_typ = match t1.term_type with
      | Ctype pt ->
        (match (Ast_types.unroll pt).tnode with
         | TPtr t -> t
         | TArray (t, _) -> t
         | _ -> pt)
      | _ -> Cil_const.intType  (* fallback *)
    in
    let deref = mk "ATunary" [("op", `String "*");
                                ("t", acsl_term_to_json tbl t1)] in
    acsl_apply_toffset tbl pointee_typ deref off
  | TLval (TResult rt, off) ->
    (* TResult of typ: frama-c carries the function return type directly on the \result node (Cil_types.ml
       term_lhost = TResult of typ), no need for outer term ty fallback. *)
    let base = mk "ATresult" [] in
    acsl_apply_toffset tbl rt base off
  | TSizeOf t1 ->
    mk "ATsizeof_type" [("arg_ty", acsl_type_to_json tbl (Ctype t1))]
  | TSizeOfE t1 ->
    mk "ATsizeof_term" [("t", acsl_term_to_json tbl t1)]
  | TAlignOf t1 ->
    mk "ATalignof" [("arg_ty", acsl_type_to_json tbl (Ctype t1))]
  | TAlignOfE t1 ->
    mk "ATalignof" [("arg_ty", acsl_type_to_json tbl t1.term_type)]
  | TUnOp (op, t1) ->
    mk "ATunary" [("op", `String (unop_to_string op));
                   ("t", acsl_term_to_json tbl t1)]
  | TBinOp (op, t1, t2) ->
    let op_str = Format.asprintf "%a" Printer.pp_binop op in
    mk "ATbinary" [("op", `String op_str);
                    ("t1", acsl_term_to_json tbl t1);
                    ("t2", acsl_term_to_json tbl t2)]
  | TCast (false, Ctype ty1, t1) ->
    mk "ATcast" [("target_ty", acsl_type_to_json tbl (Ctype ty1));
                  ("t", acsl_term_to_json tbl t1)]
  | TCast (false, lty, t1) ->
    mk "ATcast" [("target_ty", acsl_type_to_json tbl lty);
                  ("t", acsl_term_to_json tbl t1)]
  | TCast (true, _, t1) ->
    (* Implicit cast / coercion *)
    mk "ATcast" [("target_ty", acsl_type_to_json tbl t1.term_type);
                  ("t", acsl_term_to_json tbl t1)]
  (* TLogic_coerce merged into TCast in Frama-C 31.0 *)
  | Tapp (li, _, args) ->
    mk "ATapp" [("func", `String li.l_var_info.lv_name);
                 ("args", `List (List.map (acsl_term_to_json tbl) args))]
  | Tat (t1, lbl) ->
    let lbl_str = Format.asprintf "%a" Printer.pp_logic_label lbl in
    if lbl_str = "Old" then
      mk "ATold" [("t", acsl_term_to_json tbl t1)]
    else
      mk "ATat" [("t", acsl_term_to_json tbl t1); ("label", `String lbl_str)]
  | Tif (cond, t1, t2) ->
    mk "ATcond" [("cond", `String (Format.asprintf "%a" Printer.pp_predicate cond));
                  ("then_", acsl_term_to_json tbl t1);
                  ("else_", acsl_term_to_json tbl t2)]
  | Tlet (li, body) ->
    let x = li.l_var_info.lv_id in
    let t1 = match li.l_body with
      | LBterm t -> acsl_term_to_json tbl t
      | LBpred _ | LBnone | LBreads _ | LBinductive _ ->
        mk "ATnull" [] (* simplified *) in
    mk "ATlet" [("x", `Int x); ("t1", t1); ("t2", acsl_term_to_json tbl body)]
  | Tlambda (quants, body) ->
    let binders = List.map (fun lv ->
      `List [`Int lv.lv_id; acsl_type_to_json tbl lv.lv_type]
    ) quants in
    mk "ATlambda" [("binders", `List binders);
                    ("body", acsl_term_to_json tbl body)]
  | Trange (lo, hi) ->
    let fields = [] in
    let fields = match hi with
      | Some h -> ("hi", acsl_term_to_json tbl h) :: fields | None -> fields in
    let fields = match lo with
      | Some l -> ("lo", acsl_term_to_json tbl l) :: fields | None -> fields in
    mk "ATrange" fields
  | TUpdate (t1, TField (fi, TNoOffset), v) ->
    mk "ATupdate" [("t", acsl_term_to_json tbl t1);
                    ("fld", `String fi.fname);
                    ("value", acsl_term_to_json tbl v)]
  | Tnull -> mk "ATnull" []
  | Tblock_length (_, t1) ->
    mk "ATapp" [("func", `String "\\block_length");
                 ("args", `List [acsl_term_to_json tbl t1])]
  | Tbase_addr (_, t1) ->
    mk "ATapp" [("func", `String "\\base_addr");
                 ("args", `List [acsl_term_to_json tbl t1])]
  | Toffset (_, t1) ->
    mk "ATapp" [("func", `String "\\offset");
                 ("args", `List [acsl_term_to_json tbl t1])]
  | Tunion ts ->
    mk "ATapp" [("func", `String "\\union");
                 ("args", `List (List.map (acsl_term_to_json tbl) ts))]
  | Tinter ts ->
    mk "ATapp" [("func", `String "\\inter");
                 ("args", `List (List.map (acsl_term_to_json tbl) ts))]
  | Tempty_set ->
    mk "ATapp" [("func", `String "\\empty"); ("args", `List [])]
  | Tcomprehension (t1, _quants, guard) ->
    (* Simplified: use app representation *)
    let args = [acsl_term_to_json tbl t1] in
    let args = match guard with
      | Some _ -> args @ [mk "ATint_lit" [("n", `Int 0)]]
      | None -> args in
    mk "ATapp" [("func", `String "\\comprehension"); ("args", `List args)]
  | _ ->
    (* Catch-all: pretty-print as ATapp *)
    let s = Format.asprintf "%a" Printer.pp_term t in
    mk "ATapp" [("func", `String s); ("args", `List [])]

(* M-5: offset application passes CIL typ on the offset chain.
   ATfield ty = field's true type (fi.ftype).
   ATsubscript ty = array elem type (current_typ unroll and then take TArray.elem or TPtr.inner). *)
and acsl_apply_offset tbl _current_typ base rest fi =
  let field_typ = fi.ftype in
  let field_ty_json = acsl_type_to_json tbl (Ctype field_typ) in
  let field_t = mk_kind "ATfield"
    [("t", base); ("fld", `String fi.fname); ("ty", field_ty_json)] in
  acsl_apply_toffset tbl field_typ field_t rest

and acsl_apply_toffset tbl current_typ base = function
  | TNoOffset -> base
  | TField (fi, rest) -> acsl_apply_offset tbl current_typ base rest fi
  | TIndex (idx, rest) ->
    let elem_typ = match (Ast_types.unroll current_typ).tnode with
      | TArray (t, _) -> t
      | TPtr t -> t
      | _ -> current_typ
    in
    let elem_ty_json = acsl_type_to_json tbl (Ctype elem_typ) in
    let subscr = mk_kind "ATsubscript"
      [("t", base); ("idx", acsl_term_to_json tbl idx); ("ty", elem_ty_json)] in
    acsl_apply_toffset tbl elem_typ subscr rest
  | TModel _ -> base (* simplified *)

(* ====== §3.6.3: ACSL pred ====== *)

let relop_to_string = function
  | Req -> "==" | Rneq -> "!=" | Rlt -> "<" | Rgt -> ">"
  | Rle -> "<=" | Rge -> ">="

let rec acsl_pred_to_json tbl (p : predicate) : Yojson.Basic.t =
  let base = acsl_pred_node_to_json tbl p in
  (* pred_name is on the record, not a constructor *)
  match p.pred_name with
  | [] -> base
  | names ->
    List.fold_right (fun name acc ->
      mk_kind "APnamed" [("name", `String name); ("p", acc)]
    ) names base

and acsl_pred_node_to_json tbl (p : predicate) : Yojson.Basic.t =
  match p.pred_content with
  | Ptrue -> mk_kind "APtrue" []
  | Pfalse -> mk_kind "APfalse" []
  | Prel (op, t1, t2) ->
    mk_kind "APrel" [("op", `String (relop_to_string op));
                      ("t1", acsl_term_to_json tbl t1);
                      ("t2", acsl_term_to_json tbl t2)]
  | Pnot p1 ->
    mk_kind "APnot" [("p", acsl_pred_to_json tbl p1)]
  | Pand (p1, p2) ->
    mk_kind "APand" [("p1", acsl_pred_to_json tbl p1);
                      ("p2", acsl_pred_to_json tbl p2)]
  | Por (p1, p2) ->
    mk_kind "APor" [("p1", acsl_pred_to_json tbl p1);
                     ("p2", acsl_pred_to_json tbl p2)]
  | Pimplies (p1, p2) ->
    mk_kind "APimplies" [("p1", acsl_pred_to_json tbl p1);
                          ("p2", acsl_pred_to_json tbl p2)]
  | Piff (p1, p2) ->
    mk_kind "APiff" [("p1", acsl_pred_to_json tbl p1);
                      ("p2", acsl_pred_to_json tbl p2)]
  | Pxor (p1, p2) ->
    mk_kind "APxor" [("p1", acsl_pred_to_json tbl p1);
                      ("p2", acsl_pred_to_json tbl p2)]
  | Pforall (quants, p1) ->
    let binders = List.map (fun lv ->
      `List [`Int lv.lv_id; acsl_type_to_json tbl lv.lv_type]
    ) quants in
    mk_kind "APforall" [("binders", `List binders);
                         ("p", acsl_pred_to_json tbl p1)]
  | Pexists (quants, p1) ->
    let binders = List.map (fun lv ->
      `List [`Int lv.lv_id; acsl_type_to_json tbl lv.lv_type]
    ) quants in
    mk_kind "APexists" [("binders", `List binders);
                         ("p", acsl_pred_to_json tbl p1)]
  | Papp (li, _, args) ->
    mk_kind "APapp" [("func", `String li.l_var_info.lv_name);
                      ("args", `List (List.map (acsl_term_to_json tbl) args))]
  | Pif (p, p1, p2) ->
    mk_kind "APcond" [("p", acsl_pred_to_json tbl p);
                       ("p1", acsl_pred_to_json tbl p1);
                       ("p2", acsl_pred_to_json tbl p2)]
  | Pat (p1, lbl) ->
    mk_kind "APat" [("p", acsl_pred_to_json tbl p1);
                     ("label", `String (Format.asprintf "%a" Printer.pp_logic_label lbl))]
  | Plet (li, p1) ->
    (match li.l_body with
     | LBterm t ->
       mk_kind "APlet_term" [("x", `Int li.l_var_info.lv_id);
                              ("t", acsl_term_to_json tbl t);
                              ("p", acsl_pred_to_json tbl p1)]
     | LBpred q ->
       mk_kind "APlet_pred" [("x", `Int li.l_var_info.lv_id);
                              ("q", acsl_pred_to_json tbl q);
                              ("p", acsl_pred_to_json tbl p1)]
     | _ ->
       mk_kind "APlet_term" [("x", `Int li.l_var_info.lv_id);
                              ("t", mk_kind "ATnull" []);
                              ("p", acsl_pred_to_json tbl p1)])
  (* Built-in predicates → APapp *)
  | Pvalid (_, t) ->
    mk_kind "APapp" [("func", `String "\\valid");
                      ("args", `List [acsl_term_to_json tbl t])]
  | Pvalid_read (_, t) ->
    mk_kind "APapp" [("func", `String "\\valid_read");
                      ("args", `List [acsl_term_to_json tbl t])]
  | Pseparated ts ->
    mk_kind "APapp" [("func", `String "\\separated");
                      ("args", `List (List.map (acsl_term_to_json tbl) ts))]
  | Pinitialized (_, t) ->
    mk_kind "APapp" [("func", `String "\\initialized");
                      ("args", `List [acsl_term_to_json tbl t])]
  | Pdangling (_, t) ->
    mk_kind "APapp" [("func", `String "\\dangling");
                      ("args", `List [acsl_term_to_json tbl t])]
  | Pallocable (_, t) ->
    mk_kind "APapp" [("func", `String "\\allocable");
                      ("args", `List [acsl_term_to_json tbl t])]
  | Pfreeable (_, t) ->
    mk_kind "APapp" [("func", `String "\\freeable");
                      ("args", `List [acsl_term_to_json tbl t])]
  | Pfresh (_, _, t, n) ->
    mk_kind "APapp" [("func", `String "\\fresh");
                      ("args", `List [acsl_term_to_json tbl t;
                                      acsl_term_to_json tbl n])]
  | _ ->
    (* Catch-all *)
    let s = Format.asprintf "%a" Printer.pp_predicate p in
    mk_kind "APapp" [("func", `String s); ("args", `List [])]

(* ====== §3.6.4: ACSL tset ====== *)

let acsl_froms_to_tset tbl (froms : from list) : Yojson.Basic.t =
  match froms with
  | [] -> mk_kind "TSnothing" []
  | [(t, _)] -> mk_kind "TSterm" [("t", acsl_term_to_json tbl t.it_content)]
  | _ ->
    let sets = List.map (fun (t, _) ->
      mk_kind "TSterm" [("t", acsl_term_to_json tbl t.it_content)]
    ) froms in
    mk_kind "TSunion" [("sets", `List sets)]

let acsl_terms_to_tset tbl (terms : identified_term list) : Yojson.Basic.t =
  match terms with
  | [] -> mk_kind "TSnothing" []
  | [t] -> mk_kind "TSterm" [("t", acsl_term_to_json tbl t.it_content)]
  | _ ->
    let sets = List.map (fun t ->
      mk_kind "TSterm" [("t", acsl_term_to_json tbl t.it_content)]
    ) terms in
    mk_kind "TSunion" [("sets", `List sets)]

(* Extract `from` part of an assigns/loop_assigns/etc. clause.
   Each `from` is (it_content, deps); deps = FromAny | From of identified_term list.
   We collect each non-empty FromAny → empty list, From its → tset over its.
   Returns: list of TSet json (one per source location with explicit \from). *)
let acsl_froms_extract_from tbl (froms : from list) : Yojson.Basic.t list =
  List.filter_map (fun (_, deps) ->
    match deps with
    | FromAny -> None  (* No explicit \from clause *)
    | From its ->
      let terms = List.map (fun it -> it.it_content) its in
      (match terms with
       | [] -> None
       | [t] -> Some (mk_kind "TSterm" [("t", acsl_term_to_json tbl t)])
       | _ ->
         let sets = List.map (fun t ->
           mk_kind "TSterm" [("t", acsl_term_to_json tbl t)]
         ) terms in
         Some (mk_kind "TSunion" [("sets", `List sets)]))
  ) froms

(* ====== §3.6.5: ACSL contract ====== *)

let tp_kind_to_string = function
  | Assert -> "CKnone"
  | Check -> "CKcheck"
  | Admit -> "CKadmit"

let acsl_contract_to_json tbl (kf : kernel_function) : Yojson.Basic.t option =
  let spec = Annotations.funspec kf in
  if Cil.is_empty_funspec spec then None
  else
    let behaviors = List.map (fun (bhv : behavior) ->
      let clauses = ref [] in
      (* requires *)
      List.iter (fun ip ->
        clauses := mk_kind "ACrequires"
          [("ck", `String "CKnone");
           ("p", acsl_pred_to_json tbl ip.ip_content.tp_statement)]
          :: !clauses
      ) bhv.b_requires;
      (* ensures *)
      List.iter (fun (_, ip) ->
        clauses := mk_kind "ACensures"
          [("ck", `String "CKnone");
           ("p", acsl_pred_to_json tbl ip.ip_content.tp_statement)]
          :: !clauses
      ) bhv.b_post_cond;
      (* assigns *)
      (match bhv.b_assigns with
       | WritesAny -> ()
       | Writes froms ->
         let from_jsons = acsl_froms_extract_from tbl froms in
         let fields = [("locs", acsl_froms_to_tset tbl froms)] in
         let fields = if from_jsons = [] then fields
                      else fields @ [("from", `List from_jsons)] in
         clauses := mk_kind "ACassigns" fields :: !clauses);
      (* assumes *)
      List.iter (fun ip ->
        clauses := mk_kind "ACassumes"
          [("p", acsl_pred_to_json tbl ip.ip_content.tp_statement)]
          :: !clauses
      ) bhv.b_assumes;
      (* allocates/frees *)
      (match bhv.b_allocation with
       | FreeAllocAny -> ()
       | FreeAlloc (frees, allocates) ->
         if frees <> [] then
           clauses := mk_kind "ACfrees"
             [("locs", acsl_terms_to_tset tbl frees)] :: !clauses;
         if allocates <> [] then
           clauses := mk_kind "ACallocates"
             [("locs", acsl_terms_to_tset tbl allocates)] :: !clauses);
      let name = if bhv.b_name = Cil.default_behavior_name
                 then `Null else `String bhv.b_name in
      `Assoc [("name", name); ("clauses", `List (List.rev !clauses))]
    ) spec.spec_behavior in
    (* terminates *)
    let default_extra = ref [] in
    (match spec.spec_terminates with
     | Some ip ->
       default_extra := mk_kind "ACterminates"
         [("p", acsl_pred_to_json tbl ip.ip_content.tp_statement)]
         :: !default_extra
     | None -> ());
    (* variant/decreases *)
    (match spec.spec_variant with
     | Some (t, rel) ->
       let fields = [("t", acsl_term_to_json tbl t)] in
       let fields = match rel with
         | Some li -> ("rel", `String li.l_var_info.lv_name) :: fields
         | None -> fields in
       default_extra := mk_kind "ACdecreases" fields :: !default_extra
     | None -> ());
    (* Append terminates/decreases to first behavior *)
    let behaviors = match !default_extra, behaviors with
      | [], _ -> behaviors
      | extra, (`Assoc fields) :: rest ->
        let clauses = match List.assoc_opt "clauses" fields with
          | Some (`List cs) -> `List (cs @ extra)
          | _ -> `List extra in
        (`Assoc (List.map (fun (k, v) ->
          if k = "clauses" then (k, clauses) else (k, v)
        ) fields)) :: rest
      | _, _ -> behaviors in
    Some (`Assoc [
      ("behaviors", `List behaviors);
      ("complete", `List (List.map (fun names ->
        `List (List.map (fun n -> `String n) names)
      ) spec.spec_complete_behaviors));
      ("disjoint", `List (List.map (fun names ->
        `List (List.map (fun n -> `String n) names)
      ) spec.spec_disjoint_behaviors));
    ])

(* ====== §3.6.6: ACSL annotation ====== *)

let acsl_annotation_to_json tbl (ca : code_annotation) : Yojson.Basic.t =
  match ca.annot_content with
  | AAssert (bhvs, {tp_kind; tp_statement}) ->
    let fields = [("ck", `String (tp_kind_to_string tp_kind));
                  ("p", acsl_pred_to_json tbl tp_statement)] in
    let fields = if bhvs <> [] then
      ("behaviors", `List (List.map (fun s -> `String s) bhvs)) :: fields
    else fields in
    mk_kind "AAassert" fields
  | AInvariant (_, true, {tp_kind; tp_statement}) ->
    mk_kind "AAloop_invariant"
      [("ck", `String (tp_kind_to_string tp_kind));
       ("p", acsl_pred_to_json tbl tp_statement)]
  | AInvariant (_, false, {tp_kind; tp_statement}) ->
    (* General invariant → treat as assert *)
    mk_kind "AAassert"
      [("ck", `String (tp_kind_to_string tp_kind));
       ("p", acsl_pred_to_json tbl tp_statement)]
  | AVariant (t, rel) ->
    let fields = [("t", acsl_term_to_json tbl t)] in
    let fields = match rel with
      | Some li -> ("rel", `String li.l_var_info.lv_name) :: fields
      | None -> fields in
    mk_kind "AAloop_variant" fields
  | AAssigns (_, assigns) ->
    (match assigns with
     | WritesAny -> mk_kind "AAloop_assigns" [("locs", mk_kind "TSnothing" [])]
     | Writes froms ->
       let from_jsons = acsl_froms_extract_from tbl froms in
       let fields = [("locs", acsl_froms_to_tset tbl froms)] in
       let fields = if from_jsons = [] then fields
                    else fields @ [("from", `List from_jsons)] in
       mk_kind "AAloop_assigns" fields)
  | AAllocation (_, alloc) ->
    (match alloc with
     | FreeAllocAny -> mk_kind "AAloop_assigns" [("locs", mk_kind "TSnothing" [])]
     | FreeAlloc (frees, allocates) ->
       if frees <> [] then
         mk_kind "AAloop_frees" [("locs", acsl_terms_to_tset tbl frees)]
       else
         mk_kind "AAloop_allocates" [("locs", acsl_terms_to_tset tbl allocates)])
  | AStmtSpec (_, spec) ->
    (* Build a temporary funspec-like contract *)
    let contract_json = `Assoc [
      ("behaviors", `List (List.map (fun bhv ->
        let clauses = ref [] in
        List.iter (fun ip ->
          clauses := mk_kind "ACrequires"
            [("ck", `String "CKnone");
             ("p", acsl_pred_to_json tbl ip.ip_content.tp_statement)]
            :: !clauses
        ) bhv.b_requires;
        List.iter (fun (_, ip) ->
          clauses := mk_kind "ACensures"
            [("ck", `String "CKnone");
             ("p", acsl_pred_to_json tbl ip.ip_content.tp_statement)]
            :: !clauses
        ) bhv.b_post_cond;
        let name = if bhv.b_name = Cil.default_behavior_name
                   then `Null else `String bhv.b_name in
        `Assoc [("name", name); ("clauses", `List (List.rev !clauses))]
      ) spec.spec_behavior));
      ("complete", `List []);
      ("disjoint", `List []);
    ] in
    mk_kind "AAstmt_contract" [("contract", contract_json)]
  | AExtended (_bhvs, _is_loop, ext) ->
    (* Frama-C ACSL extension annotation: preserve raw form.
       AcslExtKind alignment frama-c Cil_types.acsl_extension_kind (Ext_id / Ext_terms /
       Ext_preds / Ext_annot). *)
    let kind_json = match ext.ext_kind with
      | Ext_id _      -> mk_kind "EKid" []
      | Ext_terms _   -> mk_kind "EKterms" []
      | Ext_preds _   -> mk_kind "EKpreds" []
      | Ext_annot _   -> mk_kind "EKannot" []
    in
    let payload = Format.asprintf "%a" Printer.pp_extended ext in
    mk_kind "AAextension" [("keyword", `String ext.ext_name);
                            ("kind", kind_json);
                            ("raw_payload", `List [`String payload])]

(* ====== §3.5: Labels ====== *)

let cil_label_to_json tbl (l : label) : Yojson.Basic.t =
  match l with
  | Label (name, _, from_source) ->
    mk_kind "CLgoto" [("name", `Int (goto_label_id tbl name));
                       ("from_source", `Bool from_source)]
  | Case (exp, _) ->
    let value = match Cil.constFoldToInt exp with
      | Some n -> Z.to_int n | None -> 0 in
    mk_kind "CLcase" [("value", `Int value)]
  | Default _ ->
    mk_kind "CLdefault" []

(* ====== §3.4: Statements ====== *)

let rec cil_stmt_to_json tbl (s : stmt) : Yojson.Basic.t =
  let base_json = convert_skind tbl s in
  (* Wrap with annotations from Annotations database *)
  let annots = Annotations.code_annot s in
  List.fold_right (fun ca acc ->
    let loc = stmt_loc_to_json s in
    mk_stmt_json (synth_stmt_id tbl) loc (`List [])
      (mk_kind "CilSannot"
        [("annot", acsl_annotation_to_json tbl ca);
         ("body", acc)])
  ) annots base_json

and convert_skind tbl (s : stmt) : Yojson.Basic.t =
  let loc = stmt_loc_to_json s in
  let labels = `List (List.map (cil_label_to_json tbl) s.labels) in
  let succs = List.map (fun s -> s.sid) s.succs in
  let preds = List.map (fun s -> s.sid) s.preds in
  let wrap kind = mk_stmt_json ~succs ~preds s.sid loc labels kind in
  match s.skind with
  | Instr (Set (lv, e, _)) ->
    wrap (mk_kind "CilSassign"
      [("lv", lval_to_expr_json tbl lv);
       ("rv", cil_expr_to_json tbl e)])
  | Instr (Call (ret, f, args, _)) ->
    let ret_json = match ret with
      | Some lv -> Some (lval_to_expr_json tbl lv)
      | None -> None in
    let fields = [("func", lval_to_expr_json tbl (f, NoOffset));
                  ("args", `List (List.map (cil_expr_to_json tbl) args))] in
    let fields = match ret_json with
      | Some r -> ("ret", r) :: fields | None -> fields in
    wrap (mk_kind "CilScall" fields)
  | Instr (Local_init (vi, AssignInit (SingleInit e), _)) ->
    wrap (mk_kind "CilSassign"
      [("lv", mk_kind "CilEvar" [("x", `Int (var_id tbl vi));
                                   ("ty", cil_type_to_json tbl vi.vtype)]);
       ("rv", cil_expr_to_json tbl e)])
  | Instr (Local_init (vi, ConsInit (f, args, _), _)) ->
    wrap (mk_kind "CilScall"
      [("ret", mk_kind "CilEvar" [("x", `Int (var_id tbl vi));
                                    ("ty", cil_type_to_json tbl vi.vtype)]);
       ("func", mk_kind "CilEvar" [("x", `Int (var_id tbl f));
                                     ("ty", cil_type_to_json tbl f.vtype)]);
       ("args", `List (List.map (cil_expr_to_json tbl) args))])
  | Instr (Local_init (vi, AssignInit init, _)) ->
    (* issue #25: Expand CompoundInit into multiple path-assigns. SingleInit takes one branch earlier. *)
    let rec offset_compose outer inner = match outer with
      | NoOffset -> inner
      | Field (fi, rest) -> Field (fi, offset_compose rest inner)
      | Index (e, rest) -> Index (e, offset_compose rest inner)
    in
    let rec unfold outer_off init_node : (lval * exp) list =
      match init_node with
      | SingleInit e -> [(Var vi, outer_off), e]
      | CompoundInit (_compound_ty, items) ->
        List.concat_map (fun (off, sub) ->
          unfold (offset_compose outer_off off) sub
        ) items
    in
    let assigns = unfold NoOffset init in
    (* Convert the list of (lval, exp) to the list of CilSassign JSON, and then link it into
       Right-leaning CilSsequence (use synthetic sid: s.sid * 10000 + i). Single return directly. *)
    let assign_jsons = List.map (fun (lv, e) ->
      mk_kind "CilSassign"
        [("lv", lval_to_expr_json tbl lv);
         ("rv", cil_expr_to_json tbl e)]
    ) assigns in
    (match assign_jsons with
     | [] -> wrap (mk_kind "CilSskip" [])
     | [a] -> wrap a
     | _ ->
       (* chain into right-leaning CilSsequence(a₀, CilSsequence(a₁, ..., aₙ₋₁)).
          Each inner stmt is synthesized with sid = s.sid * 10000 + idx.
          Each build_seq step consumes 2 idx: 1 for the current layer CilSsequence wrapper, 1 for s1.
          This way wrap_inner is only called once on each idx and there will be no si_id collisions.
          Upper limit: assign_jsons length needs to be < 5000 to avoid overflowing 10000 upper bound (typical for array initialization
          < 100 items, safe). *)
       let synth_sid i = s.sid * 10000 + i in
       let wrap_inner i k =
         mk_stmt_json ~succs:[] ~preds:[] (synth_sid i) loc (`List []) k
       in
       let rec build_seq idx = function
         | [] -> failwith "build_seq: empty list"
         | [last] -> wrap_inner idx last
         | hd :: tl ->
           let tail = build_seq (idx + 2) tl in
           wrap_inner idx (mk_kind "CilSsequence"
             [("s1", wrap_inner (idx + 1) hd); ("s2", tail)])
       in
       (* outer uses true s.sid + true labels, inner sequence uses composite.
          List.hd occupies idx 0; build_seq starts at idx 1. *)
       wrap (mk_kind "CilSsequence"
         [("s1", wrap_inner 0 (List.hd assign_jsons));
          ("s2", build_seq 1 (List.tl assign_jsons))]))
  | Instr (Skip _) -> wrap (mk_kind "CilSskip" [])
  | Instr (Code_annot _) ->
    (* Handled by Annotations.code_annot in cil_stmt_to_json *)
    wrap (mk_kind "CilSskip" [])
  | Instr (Asm (_, templates, asm_ext, _)) ->
    let tmpl = List.map (fun s -> `String s) templates in
    let outputs, inputs, clobbers = match asm_ext with
      | None -> ([], [], [])
      | Some ext ->
        let outs = List.map (fun (id_opt, constr, lv) ->
          let name = match id_opt with Some s -> `String s | None -> `Null in
          `Assoc [("name", name); ("constraint", `String constr);
                  ("expr", lval_to_expr_json tbl lv)]
        ) ext.asm_outputs in
        let ins = List.map (fun (id_opt, constr, e) ->
          let name = match id_opt with Some s -> `String s | None -> `Null in
          `Assoc [("name", name); ("constraint", `String constr);
                  ("expr", cil_expr_to_json tbl e)]
        ) ext.asm_inputs in
        let clobs = List.map (fun s -> `String s) ext.asm_clobbers in
        (outs, ins, clobs)
    in
    wrap (mk_kind "CilSasm" [("templates", `List tmpl);
                               ("outputs", `List outputs);
                               ("inputs", `List inputs);
                               ("clobbers", `List clobbers)])
  | Return (e_opt, _) ->
    let fields = match e_opt with
      | Some e -> [("e", cil_expr_to_json tbl e)] | None -> [] in
    wrap (mk_kind "CilSreturn" fields)
  | If (cond, tb, fb, _) ->
    wrap (mk_kind "CilSifthenelse"
      [("cond", cil_expr_to_json tbl cond);
       ("sthen", block_to_stmt_json tbl tb);
       ("selse", block_to_stmt_json tbl fb)])
  | Loop (_, body, _, _, _) ->
    wrap (mk_kind "CilSloop"
      [("body", block_to_stmt_json tbl body);
       ("incr", mk_skip_stmt ())])
  | Block b ->
    (* issue #26: Must wrap to preserve outer s.labels (CIL puts _LOR / _LAND etc.
       The synthesized goto label is placed on Block stmt. In the past, it was directly block_to_stmt_json.
       labels are discarded; label declarations cannot be found when reparsed by frama-c). *)
    wrap (mk_kind "CilSblock"
      [("body", stmts_to_sequence tbl b.bstmts);
       ("blocals", `List (List.map (fun vi ->
         `List [`Int (var_id tbl vi); cil_type_to_json tbl vi.vtype]
       ) b.blocals))])
  | Switch (e, body, _, _) ->
    wrap (mk_kind "CilSswitch"
      [("expr", cil_expr_to_json tbl e);
       ("body", block_to_stmt_json tbl body)])
  | Goto (s_ref, _) ->
    let target_name = List.find_map (fun l ->
      match l with Label (name, _, _) -> Some name | _ -> None
    ) (!s_ref).labels in
    let target = match target_name with
      | Some name -> goto_label_id tbl name
      | None -> !s_ref.sid (* fallback to sid *) in
    wrap (mk_kind "CilSgoto" [("target", `Int target)])
  | Break _ -> wrap (mk_kind "CilSbreak" [])
  | Continue _ -> wrap (mk_kind "CilScontinue" [])
  | UnspecifiedSequence seq ->
    (* Same as Block: wrap retains outer s.labels (CIL may also put _LOR / _LAND in
       UnspecifiedSequence stmt). *)
    let stmts = List.map (fun (s, _, _, _, _) -> s) seq in
    wrap (mk_kind "CilSblock"
      [("body", stmts_to_sequence tbl stmts);
       ("blocals", `List [])])
  | Throw _ | TryCatch _ | TryFinally _ | TryExcept _ ->
    wrap (mk_kind "CilSskip" [])

and block_to_stmt_json tbl (b : block) : Yojson.Basic.t =
  let body = stmts_to_sequence tbl b.bstmts in
  if b.blocals = [] then body
  else
    let blocals = List.map (fun vi ->
      `List [`Int (var_id tbl vi); cil_type_to_json tbl vi.vtype]
    ) b.blocals in
    let id = synth_stmt_id tbl in
    mk_stmt_json id `Null (`List [])
      (mk_kind "CilSblock"
        [("blocals", `List blocals); ("body", body)])

and stmts_to_sequence tbl = function
  | [] -> mk_skip_stmt ()
  | [s] -> cil_stmt_to_json tbl s
  | s :: rest ->
    let s1 = cil_stmt_to_json tbl s in
    let s2 = stmts_to_sequence tbl rest in
    let id = synth_stmt_id tbl in
    mk_stmt_json id `Null (`List [])
      (mk_kind "CilSsequence" [("s1", s1); ("s2", s2)])

(* ====== §12: Global definitions ====== *)

let composite_to_json tbl (ci : compinfo) : Yojson.Basic.t =
  let fields = match ci.cfields with
    | None -> []
    | Some flds ->
      List.map (fun fi ->
        let bf = match fi.fbitfield with
          | Some n -> `Int n | None -> `Null in
        `List [`Int (field_id tbl fi);
               cil_type_to_json tbl fi.ftype;
               bf]
      ) flds in
  `Assoc [
    ("cc_id", `Int (comp_id tbl ci));
    ("cc_is_struct", `Bool ci.cstruct);
    ("cc_fields", `List fields);
    ("cc_attr", cil_attr_to_json ci.cattr);
  ]

let enum_to_json tbl (ei : enuminfo) : Yojson.Basic.t =
  let items = List.map (fun item ->
    let value = match Cil.constFoldToInt item.eival with
      | Some n -> Z.to_int n | None -> 0 in
    (* Register item name in ident_names *)
    let item_id = enum_id tbl {ename = item.einame; eitems = [];
                                eattr = []; ereferenced = false;
                                ekind = ei.ekind; eorig_name = item.einame} in
    ignore item_id;
    `List [`Int (Hashtbl.find tbl.enum_cache item.einame);
           `Int value]
  ) ei.eitems in
  `Assoc [
    ("ce_id", `Int (enum_id tbl ei));
    ("ce_ik", `String (ikind_to_string ei.ekind));
    ("ce_items", `List items);
    ("ce_attr", cil_attr_to_json ei.eattr);
  ]

let storage_to_string (vi : varinfo) : string =
  match vi.vstorage with
  | NoStorage -> "STnone"
  | Static -> "STstatic"
  | Extern -> "STextern"
  | Register -> "STregister"

let varinfo_to_cil_varinfo tbl (vi : varinfo) : Yojson.Basic.t =
  `Assoc [("cvi_type", cil_type_to_json tbl vi.vtype);
          ("cvi_storage", `String (storage_to_string vi))]

let global_var_to_json tbl (vi : varinfo) (init : initinfo) : Yojson.Basic.t =
  let init_str = match init.init with
    | Some i -> Some (Format.asprintf "%a" Printer.pp_init_or_str i)
    | None -> None in
  let var = `Assoc [
    ("info", varinfo_to_cil_varinfo tbl vi);
    ("init", match init_str with Some s -> `String s | None -> `Null);
    ("readonly", `Bool false);
    ("volatile", `Bool (List.exists (fun (n, _) -> n = "volatile") vi.vattr));
  ] in
  mk_kind "Gvar" [("var", var)]

let extern_var_to_json tbl (vi : varinfo) : Yojson.Basic.t =
  let var = `Assoc [
    ("info", varinfo_to_cil_varinfo tbl vi);
    ("readonly", `Bool false);
    ("volatile", `Bool (List.exists (fun (n, _) -> n = "volatile") vi.vattr));
  ] in
  mk_kind "Gvar" [("var", var)]

let internal_fun_to_json tbl kf (fundec : fundec) (loc : location) : Yojson.Basic.t =
  let func_json = `Assoc [
    ("cil_fn_return", cil_type_to_json tbl (Kernel_function.get_return_type kf));
    ("cil_fn_params", `List (List.map (fun vi ->
      `List [`Int (var_id tbl vi); varinfo_to_cil_varinfo tbl vi]
    ) fundec.sformals));
    ("cil_fn_vars", `List (List.map (fun vi ->
      `List [`Int (var_id tbl vi); varinfo_to_cil_varinfo tbl vi]
    ) fundec.slocals));
    ("cil_fn_body", block_to_stmt_json tbl fundec.sbody);
    ("cil_fn_storage", `String (storage_to_string fundec.svar));
    ("cil_fn_inline", `Bool fundec.svar.vinline);
    ("cil_fn_contract", match acsl_contract_to_json tbl kf with
                         | Some c -> c | None -> `Null);
    ("cil_fn_loc", loc_to_json loc);
  ] in
  mk_kind "Internal" [("func", func_json)]

let external_fun_to_json tbl (vi : varinfo) : Yojson.Basic.t =
  (* External contract ATident ident mismatch:
     The source of param ident is changed from the (name, ty, attr) list deconstructed by vi.vtype
     Kernel_function.get_formals kf’s real varinfo list, and Internal path
     (internal_fun_to_json line 1202-1207 aligned with fundec.sformals).
     It turns out that goto_label_id is used to allocate synthetic 5_000_000+ ID, which is the same as ATident in contract.
     The lv.lv_id (frama-c internal logic_var id, has the same origin as vi.vid - cil.ml:4122-4133
     cvar_to_lvar guarantees lv_id == vi.vid) mismatch, resulting in fv-core round-trip
     emit "_id<N>" triggers frama-c "unbound logic variable" annot-error.
     Use Globals.Functions.mem to guard first. If failed, use Kernel.fatal abort instead of silent.
     fallback to the old synthetic-ID path (fallback = resurrect the original bug). *)
  let ret = match (Ast_types.unroll vi.vtype).tnode with
    | TFun (ret, _params, _va) -> ret
    | _ -> vi.vtype in
  if not (Globals.Functions.mem vi) then
    Kernel.fatal
      "external_fun_to_json: function %s has no associated kernel_function. \
       This contradicts the fix's assumption. \
       Likely cause: frama-c API change or vi not from a valid External decl."
      vi.vname;
  let kf = Globals.Functions.get vi in
  let params = `List (List.map (fun (vi_formal : varinfo) ->
    `List [`Int (var_id tbl vi_formal); varinfo_to_cil_varinfo tbl vi_formal]
  ) (Kernel_function.get_formals kf)) in
  let contract_field =
    match acsl_contract_to_json tbl kf with
    | Some c -> [("contract", c)]
    | None -> []
  in
  mk_kind "External" ([("params", params);
                        ("ret", cil_type_to_json tbl ret);
                        ("cc", `Assoc [])] @ contract_field)

(* ====== §12.5: ACSL global definitions (issue #27) ======
   Output frama-c
   `Cil_types.global_annotation` 8 out of 10 variants suitable for the fv-core data model.
   Dvolatile / Dmodel_annot skipped (no corresponding ctor on fv-core side). Dmodule temporary reuse
   ALDaxiomatic encoding. *)

(* Helper: extract reads list from a logic_info body if present. *)
let logic_info_reads tbl (li : logic_info) : Yojson.Basic.t list =
  match li.l_body with
  | LBreads its ->
    (* `\reads` child clause: list of identified_term *)
    List.map (fun it ->
      mk_kind "TSterm" [("t", acsl_term_to_json tbl it.it_content)]
    ) its
  | _ -> []

(* Helper: extract optional body term/pred from logic_info. *)
let logic_info_body_term tbl (li : logic_info) : Yojson.Basic.t option =
  match li.l_body with
  | LBterm t -> Some (acsl_term_to_json tbl t)
  | _ -> None

let logic_info_body_pred tbl (li : logic_info) : Yojson.Basic.t option =
  match li.l_body with
  | LBpred p -> Some (acsl_pred_to_json tbl p)
  | _ -> None

(* Helper: convert logic_var_info (logic-level varinfo) to (Ident, AcslType) tuple. *)
let logic_var_to_param_json tbl (lv : logic_var) : Yojson.Basic.t =
  `List [`Int lv.lv_id; acsl_type_to_json tbl lv.lv_type]

let rec acsl_logic_def_to_json tbl (ga : global_annotation) : Yojson.Basic.t option =
  match ga with
  | Dfun_or_pred (li, _loc) ->
    (* logic function vs predicate: predicate has l_type = None.
       inductive: body is LBinductive. *)
    let params_json = `List (List.map (logic_var_to_param_json tbl) li.l_profile) in
    let ty_params_json = `List (List.map (fun s -> `String s) li.l_tparams) in
    let name = li.l_var_info.lv_name in
    (match li.l_body with
     | LBinductive cases ->
       (* inductive predicate *)
       let cases_json = `List (List.map (fun (case_name, _labels, _ty_params, p) ->
         `List [`String case_name; acsl_pred_to_json tbl p]
       ) cases) in
       Some (mk_kind "ALDinductive"
         [("name", `String name);
          ("params", params_json);
          ("cases", cases_json)])
     | _ ->
       (match li.l_type with
        | None ->
          (* predicate *)
          let body_field = match logic_info_body_pred tbl li with
            | Some p -> [("body", p)] | None -> [] in
          let reads_field =
            let rs = logic_info_reads tbl li in
            if rs = [] then [] else [("reads", `List rs)] in
          Some (mk_kind "ALDpredicate"
            ([("name", `String name);
              ("ty_params", ty_params_json);
              ("params", params_json)] @ body_field @ reads_field))
        | Some ret_ty ->
          (* logic function *)
          let body_field = match logic_info_body_term tbl li with
            | Some t -> [("body", t)] | None -> [] in
          let reads_field =
            let rs = logic_info_reads tbl li in
            if rs = [] then [] else [("reads", `List rs)] in
          Some (mk_kind "ALDfunction"
            ([("name", `String name);
              ("ty_params", ty_params_json);
              ("params", params_json);
              ("ret_ty", acsl_type_to_json tbl ret_ty)] @ body_field @ reads_field))))

  | Daxiomatic (name, defs, _attrs, _loc) ->
    Some (mk_kind "ALDaxiomatic"
      [("name", `String name);
       ("defs", `List (List.filter_map (acsl_logic_def_to_json tbl) defs))])

  | Dmodule (name, defs, _attrs, _loader, _loc) ->
    (* Frama-C 31.0 ACSL module — fv-core temporarily reuses ALDaxiomatic encoding (semantic approximation:
       Both are named logic def containers, loader metadata is lost but def content is preserved). *)
    Some (mk_kind "ALDaxiomatic"
      [("name", `String name);
       ("defs", `List (List.filter_map (acsl_logic_def_to_json tbl) defs))])

  | Dlemma (name, _labels, _ty_params, tp, _attrs, _loc) ->
    (* axiom/lemma distinguish by tp.tp_kind: predicate_kind = Assert | Check | Admit
       (cil_types.ml:138). doc-comment "axioms are admit lemmas": Admit -> axiom. *)
    let ctor = match tp.tp_kind with
      | Admit -> "ALDaxiom"
      | Assert | Check -> "ALDlemma"
    in
    Some (mk_kind ctor
      [("name", `String name);
       ("p", acsl_pred_to_json tbl tp.tp_statement)])

  | Dtype (lti, _loc) ->
    (* Only LTsyn (synonym) has simple def; LTsum (datatype) temporary output (fv-core
       ALDtype.def: Option<AcslType> single type, does not support sum constructor list). *)
    let def_field = match lti.lt_def with
      | Some (LTsyn ty) -> [("def", acsl_type_to_json tbl ty)]
      | _ -> []
    in
    Some (mk_kind "ALDtype"
      ([("name", `String lti.lt_name);
        ("ty_params", `List (List.map (fun s -> `String s) lti.lt_params))]
       @ def_field))

  | Dinvariant (li, _loc) ->
    (* Global invariant: predicate no type parameter. fv-core ALDtype_invariant.ty uses Null
       Placeholder (fv-core side Null is changed to a suitable fallback when deserialization fails - accepted by this fix
       For details about this gap, see §5.7 Description of the semantic loss of Dinvariant vs Dtype_annot merging). *)
    let p = match logic_info_body_pred tbl li with
      | Some p -> p
      | None -> mk_kind "APtrue" [] in
    Some (mk_kind "ALDtype_invariant"
      [("name", `String li.l_var_info.lv_name);
       ("ty", mk_kind "ACTYlogic" [("name", `String "boolean")]);
       ("p", p)])

  | Dtype_annot (li, _loc) ->
    (* Type invariant: predicate single parameter (the parameter type is the type to which the invariant belongs). *)
    let p = match logic_info_body_pred tbl li with
      | Some p -> p
      | None -> mk_kind "APtrue" [] in
    let ty = match li.l_profile with
      | [param] -> acsl_type_to_json tbl param.lv_type
      | _ -> mk_kind "ACTYlogic" [("name", `String "boolean")] in
    Some (mk_kind "ALDtype_invariant"
      [("name", `String li.l_var_info.lv_name);
       ("ty", ty);
       ("p", p)])

  | Dvolatile _ -> None (* fv-core does not support volatile global, skip *)

  | Dmodel_annot _ -> None (* fv-core does not support model field, skip *)

  | Dextended (ext, _attrs, _loc) ->
    let kind_json = match ext.ext_kind with
      | Ext_id _      -> mk_kind "EKid" []
      | Ext_terms _   -> mk_kind "EKterms" []
      | Ext_preds _   -> mk_kind "EKpreds" []
      | Ext_annot _   -> mk_kind "EKannot" []
    in
    let payload = Format.asprintf "%a" Printer.pp_extended ext in
    Some (mk_kind "ALDextension"
      [("keyword", `String ext.ext_name);
       ("kind", kind_json);
       ("raw_payload", `List [`String payload])])

let dump_acsl_globals tbl : Yojson.Basic.t =
  let acc = ref [] in
  Annotations.iter_global (fun _emitter ga ->
    match acsl_logic_def_to_json tbl ga with
    | Some j -> acc := j :: !acc
    | None -> ()
  );
  `List (List.rev !acc)

(* ====== §13: collect_includes ====== *)

let collect_includes () : string list =
  let extract_file acc = function
    | AStr s -> Datatype.String.Set.add
        (Filepath.to_string (Filepath.of_string s)) acc
    | _ -> acc in
  let add_file acc g =
    Ast_attributes.(find_params fc_stdlib (Cil_datatype.Global.attr g))
    |> List.fold_left extract_file acc in
  let includes = List.fold_left add_file
    Datatype.String.Set.empty (Ast.get ()).globals in
  Datatype.String.Set.elements includes

(* ====== §14: dump_project ====== *)

let machdep_to_json () : Yojson.Basic.t =
  let m = Machine.get_machdep () in
  `Assoc [
    ("sizeof_short", `Int m.sizeof_short);
    ("sizeof_int", `Int m.sizeof_int);
    ("sizeof_long", `Int m.sizeof_long);
    ("sizeof_longlong", `Int m.sizeof_longlong);
    ("sizeof_ptr", `Int m.sizeof_ptr);
    ("sizeof_float", `Int m.sizeof_float);
    ("sizeof_double", `Int m.sizeof_double);
    ("sizeof_longdouble", `Int m.sizeof_longdouble);
    ("big_endian", `Bool (not m.little_endian));
    ("char_unsigned", `Bool m.char_is_unsigned);
    ("alignof_int64", `Int m.alignof_longlong);
    ("alignof_float64", `Int m.alignof_double);
  ]

let dump_project () : Yojson.Basic.t =
  let tbl = create_ident_table () in
  let globals = (Ast.get ()).globals in

  let composites = ref [] in
  let enums = ref [] in
  let prog_defs = ref [] in  (* unified (ident, GlobDef) list *)
  let defined_func_ids = Hashtbl.create 32 in  (* vid → () *)
  let defined_var_ids = Hashtbl.create 32 in   (* vid → () *)

  (* Pass 1: types + globals + internal functions *)
  List.iter (fun g -> match g with
    | GCompTag (ci, _) | GCompTagDecl (ci, _) ->
      if not (List.exists (fun j -> match j with
        | `Assoc fields -> (match List.assoc_opt "cc_id" fields with
          | Some (`Int id) -> id = 1_000_000 + ci.ckey | _ -> false)
        | _ -> false) !composites) then
        composites := composite_to_json tbl ci :: !composites
    | GEnumTag (ei, _) | GEnumTagDecl (ei, _) ->
      if not (Hashtbl.mem tbl.enum_cache ei.ename) then
        enums := enum_to_json tbl ei :: !enums
    | GType _ -> () (* typedefs: CTnamed inlines the underlying type, no separate entry *)
    | GVar (vi, init, _) ->
      let id = var_id tbl vi in
      Hashtbl.replace defined_var_ids vi.vid ();
      prog_defs := (id, global_var_to_json tbl vi init) :: !prog_defs
    | GFun (fundec, loc) ->
      let kf = Globals.Functions.get fundec.svar in
      let id = var_id tbl fundec.svar in
      Hashtbl.replace defined_func_ids fundec.svar.vid ();
      let fundef = internal_fun_to_json tbl kf fundec loc in
      prog_defs := (id, mk_kind "Gfun" [("def", fundef)]) :: !prog_defs
    | _ -> ()
  ) globals;

  (* Pass 2: external function decls + extern variable decls *)
  List.iter (fun g -> match g with
    | GFunDecl (_, vi, _) when Ast_types.is_fun vi.vtype
                             && not (Hashtbl.mem defined_func_ids vi.vid) ->
      let id = var_id tbl vi in
      Hashtbl.replace defined_func_ids vi.vid ();
      let fundef = external_fun_to_json tbl vi in
      prog_defs := (id, mk_kind "Gfun" [("def", fundef)]) :: !prog_defs
    | GVarDecl (vi, _) when not (Hashtbl.mem defined_var_ids vi.vid) ->
      let id = var_id tbl vi in
      Hashtbl.replace defined_var_ids vi.vid ();
      prog_defs := (id, extern_var_to_json tbl vi) :: !prog_defs
    | _ -> ()
  ) globals;

  let includes = collect_includes () in
  let files = List.map Filepath.to_string (Kernel.Files.get ()) in
  let main_id = try
    let kf, _ = Globals.entry_point () in
    Some (var_id tbl (Kernel_function.get_vi kf))
  with _ -> None in

  (* prog_defs as list of [ident, globdef] pairs *)
  let prog_defs_json = `List (List.rev_map (fun (id, gd) ->
    `List [`Int id; gd]
  ) !prog_defs) in

  `Assoc [
    ("prog_defs", prog_defs_json);
    ("prog_public", `List []);  (* TODO: collect public symbols *)
    ("prog_main", (match main_id with Some id -> `Int id | None -> `Null));
    ("ident_names", ident_names_to_json tbl);
    ("acsl_globals", dump_acsl_globals tbl);
    ("includes", `List (List.map (fun s -> `String s) includes));
    ("composites", `List (List.rev !composites));
    ("enums", `List (List.rev !enums));
    ("filename", `String (match files with f :: _ -> f | [] -> ""));
    ("pragmas", `List []);
    ("texts", `List []);
    ("machdep", machdep_to_json ());
    ("version", `String "fcil-1.0");
    ("files", `List (List.map (fun f -> `String f) files));
  ]
