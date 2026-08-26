(* Kernel API spellings that differ between the Frama-C releases this plug-in
   supports, wrapped so a call site reads the same on 32.1 and on 33.

   Every difference a function can absorb lives here. Two do not, and stay in
   ast_utils_export.ml: the ikind and fkind match arms, because 32.1 has no
   IInt128, IUInt128, FFloat32 or FFloat64 to name and a wrapper cannot hide a
   constructor that does not exist. Everything else is a wrapper, including the
   Tif and Pif condition, which is a field whose type changed rather than a
   missing constructor and so can be absorbed like the rest.

   Frama-C 33 changed several things this plug-in reaches for. A location is now a
   pair of abstract Filepos.t rather than a pair of Filepath.position records,
   so the record fields are a type error rather than a deprecation. The
   Cil_datatype.Location alias is deprecated in favour of Fileloc, and dune's
   default flags turn that alert into an error. And Cil.mkBinOp returns a
   result, with the raising version renamed to mkBinOp_exn.

   The position accessors below are field-for-field what filepath.mli's own
   deprecation notes name as the replacements: pos_path is Filepos.path,
   pos_lnum is Filepos.line, and pos_cnum minus pos_bol is
   Filepos.input_column. So the two arms report the same position, including
   for preprocessed input, where Filepos.path and Filepos.line answer about
   the original file rather than the preprocessor's output. *)

open Frama_c_kernel
open Cil_types

let loc_unknown : location =
#if FRAMAC_MAJOR >= 33
  Fileloc.unknown
#else
  Cil_datatype.Location.unknown
#endif

let loc_is_unknown (loc : location) : bool =
#if FRAMAC_MAJOR >= 33
  Fileloc.equal loc Fileloc.unknown
#else
  Cil_datatype.Location.equal loc Cil_datatype.Location.unknown
#endif

let loc_file (loc : location) : string =
#if FRAMAC_MAJOR >= 33
  Filepath.to_string (Filepos.path (fst loc))
#else
  Filepath.to_string (fst loc).Filepath.pos_path
#endif

let loc_line (loc : location) : int =
#if FRAMAC_MAJOR >= 33
  Filepos.line (fst loc)
#else
  (fst loc).Filepath.pos_lnum
#endif

let loc_col (loc : location) : int =
#if FRAMAC_MAJOR >= 33
  Filepos.input_column (fst loc)
#else
  let pos = fst loc in
  pos.Filepath.pos_cnum - pos.Filepath.pos_bol
#endif

(* Raises on operands mkBinOp cannot type, which is what the ghost parser
   wants: its callers report the failure as a parse error. Constant folding is
   forced on both arms, because 33 made it opt-in and defaults it off while
   every earlier release folded unconditionally. *)
let mk_binop ~loc op e1 e2 : exp =
#if FRAMAC_MAJOR >= 33
  Cil.mkBinOp_exn ~constfold:true ~loc op e1 e2
#else
  Cil.mkBinOp ~loc op e1 e2
#endif

(* The condition of an ACSL conditional, printed.

   Tif and Pif carry a term before 33 and a predicate from 33 on. Both call
   sites want the same thing out of it, a string for the payload, so the
   difference stops here instead of forking the exported schema by version. *)
let if_cond_to_string c =
#if FRAMAC_MAJOR >= 33
  Format.asprintf "%a" Printer.pp_predicate c
#else
  Format.asprintf "%a" Printer.pp_term c
#endif
