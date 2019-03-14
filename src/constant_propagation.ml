(**************************************************************************)
(*     Sail                                                               *)
(*                                                                        *)
(*  Copyright (c) 2013-2017                                               *)
(*    Kathyrn Gray                                                        *)
(*    Shaked Flur                                                         *)
(*    Stephen Kell                                                        *)
(*    Gabriel Kerneis                                                     *)
(*    Robert Norton-Wright                                                *)
(*    Christopher Pulte                                                   *)
(*    Peter Sewell                                                        *)
(*    Alasdair Armstrong                                                  *)
(*    Brian Campbell                                                      *)
(*    Thomas Bauereiss                                                    *)
(*    Anthony Fox                                                         *)
(*    Jon French                                                          *)
(*    Dominic Mulligan                                                    *)
(*    Stephen Kell                                                        *)
(*    Mark Wassell                                                        *)
(*                                                                        *)
(*  All rights reserved.                                                  *)
(*                                                                        *)
(*  This software was developed by the University of Cambridge Computer   *)
(*  Laboratory as part of the Rigorous Engineering of Mainstream Systems  *)
(*  (REMS) project, funded by EPSRC grant EP/K008528/1.                   *)
(*                                                                        *)
(*  Redistribution and use in source and binary forms, with or without    *)
(*  modification, are permitted provided that the following conditions    *)
(*  are met:                                                              *)
(*  1. Redistributions of source code must retain the above copyright     *)
(*     notice, this list of conditions and the following disclaimer.      *)
(*  2. Redistributions in binary form must reproduce the above copyright  *)
(*     notice, this list of conditions and the following disclaimer in    *)
(*     the documentation and/or other materials provided with the         *)
(*     distribution.                                                      *)
(*                                                                        *)
(*  THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS''    *)
(*  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED     *)
(*  TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A       *)
(*  PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR   *)
(*  CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,          *)
(*  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT      *)
(*  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF      *)
(*  USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND   *)
(*  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,    *)
(*  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT    *)
(*  OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF    *)
(*  SUCH DAMAGE.                                                          *)
(**************************************************************************)

open Ast
open Ast_util
open Spec_analysis
open Type_check

(* COULD DO: dead code is only eliminated at if expressions, but we could
   also cut out impossible case branches and code after assertions. *)

(* Constant propogation.
   Takes maps of immutable/mutable variables to subsitute.
   The substs argument also contains the current type-level kid refinements
   so that we can check for dead code.
   Extremely conservative about evaluation order of assignments in
   subexpressions, dropping assignments rather than committing to
   any particular order *)


let kbindings_from_list = List.fold_left (fun s (v,i) -> KBindings.add v i s) KBindings.empty
let bindings_from_list = List.fold_left (fun s (v,i) -> Bindings.add v i s) Bindings.empty
(* union was introduced in 4.03.0, a bit too recently *)
let bindings_union s1 s2 =
  Bindings.merge (fun _ x y -> match x,y with
  |  _, (Some x) -> Some x
  |  (Some x), _ -> Some x
  |  _,  _ -> None) s1 s2
let kbindings_union s1 s2 =
  KBindings.merge (fun _ x y -> match x,y with
  |  _, (Some x) -> Some x
  |  (Some x), _ -> Some x
  |  _,  _ -> None) s1 s2

let rec list_extract f = function
  | [] -> None
  | h::t -> match f h with None -> list_extract f t | Some v -> Some v



let is_pure e =
  match e with
  | Effect_aux (Effect_set [],_) -> true
  | _ -> false

let remove_bound (substs,ksubsts) pat =
  let bound = bindings_from_pat pat in
  List.fold_left (fun sub v -> Bindings.remove v sub) substs bound, ksubsts

let rec is_value (E_aux (e,(l,annot))) =
  let is_constructor id =
    match destruct_tannot annot with
    | None ->
       (Reporting.print_err l "Monomorphisation"
          ("Missing type information for identifier " ^ string_of_id id);
        false) (* Be conservative if we have no info *)
    | Some (env,_,_) ->
       Env.is_union_constructor id env ||
         (match Env.lookup_id id env with
         | Enum _ -> true
         | Unbound | Local _ | Register _ -> false)
  in
  match e with
  | E_id id -> is_constructor id
  | E_lit _ -> true
  | E_tuple es -> List.for_all is_value es
  | E_app (id,es) -> is_constructor id && List.for_all is_value es
  (* We add casts to undefined to keep the type information in the AST *)
  | E_cast (typ,E_aux (E_lit (L_aux (L_undef,_)),_)) -> true
(* TODO: more? *)
  | _ -> false

let isubst_minus_set subst set =
  IdSet.fold Bindings.remove set subst

let threaded_map f state l =
  let l',state' =
    List.fold_left (fun (tl,state) element -> let (el',state') = f state element in (el'::tl,state'))
      ([],state) l
  in List.rev l',state'


(* Attempt simple pattern matches *)
let lit_match = function
  | (L_zero | L_false), (L_zero | L_false) -> true
  | (L_one  | L_true ), (L_one  | L_true ) -> true
  | L_num i1, L_num i2 -> Big_int.equal i1 i2
  | l1,l2 -> l1 = l2

(* There's no undefined nexp, so replace undefined sizes with a plausible size.
   32 is used as a sensible default. *)

let fabricate_nexp_exist env l typ kids nc typ' =
  match kids,nc,Env.expand_synonyms env typ' with
  | ([kid],NC_aux (NC_set (kid',i::_),_),
     Typ_aux (Typ_app (Id_aux (Id "atom",_),
                       [A_aux (A_nexp (Nexp_aux (Nexp_var kid'',_)),_)]),_))
      when Kid.compare kid kid' = 0 && Kid.compare kid kid'' = 0 ->
     Nexp_aux (Nexp_constant i,Unknown)
  | ([kid],NC_aux (NC_true,_),
     Typ_aux (Typ_app (Id_aux (Id "atom",_),
                       [A_aux (A_nexp (Nexp_aux (Nexp_var kid'',_)),_)]),_))
      when Kid.compare kid kid'' = 0 ->
     nint 32
  | ([kid],NC_aux (NC_set (kid',i::_),_),
     Typ_aux (Typ_app (Id_aux (Id "range",_),
                       [A_aux (A_nexp (Nexp_aux (Nexp_var kid'',_)),_);
                        A_aux (A_nexp (Nexp_aux (Nexp_var kid''',_)),_)]),_))
      when Kid.compare kid kid' = 0 && Kid.compare kid kid'' = 0 &&
        Kid.compare kid kid''' = 0 ->
     Nexp_aux (Nexp_constant i,Unknown)
  | ([kid],NC_aux (NC_true,_),
     Typ_aux (Typ_app (Id_aux (Id "range",_),
                       [A_aux (A_nexp (Nexp_aux (Nexp_var kid'',_)),_);
                        A_aux (A_nexp (Nexp_aux (Nexp_var kid''',_)),_)]),_))
      when Kid.compare kid kid'' = 0 &&
        Kid.compare kid kid''' = 0 ->
     nint 32
  | ([], _, typ) -> nint 32
  | (kids, nc, typ) ->
     raise (Reporting.err_general l
              ("Undefined value at unsupported type " ^ string_of_typ typ ^ " with " ^ Util.string_of_list ", " string_of_kid kids))

let fabricate_nexp l tannot =
  match destruct_tannot tannot with
  | None -> nint 32
  | Some (env,typ,_) ->
     match Type_check.destruct_exist (Type_check.Env.expand_synonyms env typ) with
     | None -> nint 32
     (* TODO: check this *)
     | Some (kopts,nc,typ') -> fabricate_nexp_exist env l typ (List.map kopt_kid kopts) nc typ'

let atom_typ_kid kid = function
  | Typ_aux (Typ_app (Id_aux (Id "atom",_),
                      [A_aux (A_nexp (Nexp_aux (Nexp_var kid',_)),_)]),_) ->
     Kid.compare kid kid' = 0
  | _ -> false

(* We reduce casts in a few cases, in particular to ensure that where the
   type checker has added a ({'n, true. atom('n)}) ex_int(...) cast we can
   fill in the 'n.  For undefined we fabricate a suitable value for 'n. *)

let reduce_cast typ exp l annot =
  let env = env_of_annot (l,annot) in
  let typ' = Env.base_typ_of env typ in
  match exp, destruct_exist (Env.expand_synonyms env typ') with
  | E_aux (E_lit (L_aux (L_num n,_)),_), Some ([kopt],nc,typ'') when atom_typ_kid (kopt_kid kopt) typ'' ->
     let nc_env = Env.add_typ_var l kopt env in
     let nc_env = Env.add_constraint (nc_eq (nvar (kopt_kid kopt)) (nconstant n)) nc_env in
     if prove __POS__ nc_env nc
     then exp
     else raise (Reporting.err_unreachable l __POS__
                   ("Constant propagation error: literal " ^ Big_int.to_string n ^
                       " does not satisfy constraint " ^ string_of_n_constraint nc))
  | E_aux (E_lit (L_aux (L_undef,_)),_), Some ([kopt],nc,typ'') when atom_typ_kid (kopt_kid kopt) typ'' ->
     let nexp = fabricate_nexp_exist env Unknown typ [kopt_kid kopt] nc typ'' in
     let newtyp = subst_kids_typ (KBindings.singleton (kopt_kid kopt) nexp) typ'' in
     E_aux (E_cast (newtyp, exp), (Generated l,replace_typ newtyp annot))
  | E_aux (E_cast (_,
                   (E_aux (E_lit (L_aux (L_undef,_)),_) as exp)),_),
     Some ([kopt],nc,typ'') when atom_typ_kid (kopt_kid kopt) typ'' ->
     let nexp = fabricate_nexp_exist env Unknown typ [kopt_kid kopt] nc typ'' in
     let newtyp = subst_kids_typ (KBindings.singleton (kopt_kid kopt) nexp) typ'' in
     E_aux (E_cast (newtyp, exp), (Generated l,replace_typ newtyp annot))
  | _ -> E_aux (E_cast (typ,exp),(l,annot))

(* Used for constant propagation in pattern matches *)
type 'a matchresult =
  | DoesMatch of 'a
  | DoesNotMatch
  | GiveUp

(* Remove top-level casts from an expression.  Useful when we need to look at
   subexpressions to reduce something, but could break type-checking if we used
   it everywhere. *)
let rec drop_casts = function
  | E_aux (E_cast (_,e),_) -> drop_casts e
  | exp -> exp

let int_of_str_lit = function
  | L_hex hex -> Big_int.of_string ("0x" ^ hex)
  | L_bin bin -> Big_int.of_string ("0b" ^ bin)
  | _ -> assert false

let bits_of_lit = function
  | L_bin bin -> bin
  | L_hex hex -> hex_to_bin hex
  | _ -> assert false

let slice_lit (L_aux (lit,ll)) i len (Ord_aux (ord,_)) =
  let i = Big_int.to_int i in
  let len = Big_int.to_int len in
  let bin = bits_of_lit lit in
  match match ord with
  | Ord_inc -> Some i
  | Ord_dec -> Some (String.length bin - i - len)
  | Ord_var _ -> None
  with
  | None -> None
  | Some i ->
     Some (L_aux (L_bin (String.sub bin i len),Generated ll))

let concat_vec lit1 lit2 =
  let bits1 = bits_of_lit lit1 in
  let bits2 = bits_of_lit lit2 in
  L_bin (bits1 ^ bits2)

let lit_eq (L_aux (l1,_)) (L_aux (l2,_)) =
  match l1,l2 with
  | (L_zero|L_false), (L_zero|L_false)
  | (L_one |L_true ), (L_one |L_true)
    -> Some true
  | (L_hex _| L_bin _), (L_hex _|L_bin _)
    -> Some (Big_int.equal (int_of_str_lit l1) (int_of_str_lit l2))
  | L_undef, _ | _, L_undef -> None
  | L_num i1, L_num i2 -> Some (Big_int.equal i1 i2)
  | _ -> Some (l1 = l2)

let try_app (l,ann) (id,args) =
  let new_l = Parse_ast.Generated l in
  let env = env_of_annot (l,ann) in
  let get_overloads f = List.map string_of_id
    (Env.get_overloads (Id_aux (Id f, Parse_ast.Unknown)) env @
    Env.get_overloads (Id_aux (DeIid f, Parse_ast.Unknown)) env) in
  let is_id f = List.mem (string_of_id id) (f :: get_overloads f) in
  if is_id "==" || is_id "!=" then
    match args with
    | [E_aux (E_lit l1,_); E_aux (E_lit l2,_)] ->
       let lit b = if b then L_true else L_false in
       let lit b = lit (if is_id "==" then b else not b) in
       (match lit_eq l1 l2 with
       | None -> None
       | Some b -> Some (E_aux (E_lit (L_aux (lit b,new_l)),(l,ann))))
    | _ -> None
  else if is_id "cast_bit_bool" then
    match args with
    | [E_aux (E_lit L_aux (L_zero,_),_)] -> Some (E_aux (E_lit (L_aux (L_false,new_l)),(l,ann)))
    | [E_aux (E_lit L_aux (L_one ,_),_)] -> Some (E_aux (E_lit (L_aux (L_true ,new_l)),(l,ann)))
    | _ -> None
  else if is_id "UInt" || is_id "unsigned" then
    match args with
    | [E_aux (E_lit L_aux ((L_hex _| L_bin _) as lit,_), _)] ->
       Some (E_aux (E_lit (L_aux (L_num (int_of_str_lit lit),new_l)),(l,ann)))
    | _ -> None
  else if is_id "slice" then
    match args with
    | [E_aux (E_lit (L_aux ((L_hex _| L_bin _),_) as lit), annot);
       E_aux (E_lit L_aux (L_num i,_), _);
       E_aux (E_lit L_aux (L_num len,_), _)] ->
       (match Env.base_typ_of (env_of_annot annot) (typ_of_annot annot) with
       | Typ_aux (Typ_app (_,[_;A_aux (A_order ord,_);_]),_) ->
          (match slice_lit lit i len ord with
          | Some lit' -> Some (E_aux (E_lit lit',(l,ann)))
          | None -> None)
       | _ -> None)
    | _ -> None
  else if is_id "bitvector_concat" then
    match args with
    | [E_aux (E_lit L_aux ((L_hex _| L_bin _) as lit1,_), _);
       E_aux (E_lit L_aux ((L_hex _| L_bin _) as lit2,_), _)] ->
       Some (E_aux (E_lit (L_aux (concat_vec lit1 lit2,new_l)),(l,ann)))
    | _ -> None
  else if is_id "shl_int" then
    match args with
    | [E_aux (E_lit L_aux (L_num i,_),_); E_aux (E_lit L_aux (L_num j,_),_)] ->
       Some (E_aux (E_lit (L_aux (L_num (Big_int.shift_left i (Big_int.to_int j)),new_l)),(l,ann)))
    | _ -> None
  else if is_id "mult_atom" || is_id "mult_int" || is_id "mult_range" then
    match args with
    | [E_aux (E_lit L_aux (L_num i,_),_); E_aux (E_lit L_aux (L_num j,_),_)] ->
       Some (E_aux (E_lit (L_aux (L_num (Big_int.mul i j),new_l)),(l,ann)))
    | _ -> None
  else if is_id "quotient_nat" then
    match args with
    | [E_aux (E_lit L_aux (L_num i,_),_); E_aux (E_lit L_aux (L_num j,_),_)] ->
       Some (E_aux (E_lit (L_aux (L_num (Big_int.div i j),new_l)),(l,ann)))
    | _ -> None
  else if is_id "add_atom" || is_id "add_int" || is_id "add_range" then
    match args with
    | [E_aux (E_lit L_aux (L_num i,_),_); E_aux (E_lit L_aux (L_num j,_),_)] ->
       Some (E_aux (E_lit (L_aux (L_num (Big_int.add i j),new_l)),(l,ann)))
    | _ -> None
  else if is_id "negate_range" then
    match args with
    | [E_aux (E_lit L_aux (L_num i,_),_)] ->
       Some (E_aux (E_lit (L_aux (L_num (Big_int.negate i),new_l)),(l,ann)))
    | _ -> None
  else if is_id "ex_int" then
    match args with
    | [E_aux (E_lit lit,(l,_))] -> Some (E_aux (E_lit lit,(l,ann)))
    | [E_aux (E_cast (_,(E_aux (E_lit (L_aux (L_undef,_)),_) as e)),(l,_))] ->
       Some (reduce_cast (typ_of_annot (l,ann)) e l ann)
    | _ -> None
  else if is_id "vector_access" || is_id "bitvector_access" then
    match args with
    | [E_aux (E_lit L_aux ((L_hex _ | L_bin _) as lit,_),_);
       E_aux (E_lit L_aux (L_num i,_),_)] ->
       let v = int_of_str_lit lit in
       let b = Big_int.bitwise_and (Big_int.shift_right v (Big_int.to_int i)) (Big_int.of_int 1) in
       let lit' = if Big_int.equal b (Big_int.of_int 1) then L_one else L_zero in
       Some (E_aux (E_lit (L_aux (lit',new_l)),(l,ann)))
    | _ -> None
  else None


let construct_lit_vector args =
  let rec aux l = function
    | [] -> Some (L_aux (L_bin (String.concat "" (List.rev l)),Unknown))
    | E_aux (E_lit (L_aux ((L_zero | L_one) as lit,_)),_)::t ->
       aux ((if lit = L_zero then "0" else "1")::l) t
    | _ -> None
  in aux [] args

(* Add a cast to undefined so that it retains its type, otherwise it can't be
   substituted safely *)
let keep_undef_typ value =
  match value with
  | E_aux (E_lit (L_aux (L_undef,lann)),eann) ->
     E_aux (E_cast (typ_of_annot eann,value),(Generated Unknown,snd eann))
  | _ -> value

(* Check whether the current environment with the given kid assignments is
   inconsistent (and hence whether the code is dead) *)
let is_env_inconsistent env ksubsts =
  let env = KBindings.fold (fun k nexp env ->
    Env.add_constraint (nc_eq (nvar k) nexp) env) ksubsts env in
  prove __POS__ env nc_false


let const_props defs ref_vars =
  let rec const_prop_exp substs assigns ((E_aux (e,(l,annot))) as exp) =
    (* Functions to treat lists and tuples of subexpressions as possibly
       non-deterministic: that is, we stop making any assumptions about
       variables that are assigned to in any of the subexpressions *)
    let non_det_exp_list es =
      let assigned_in =
        List.fold_left (fun vs exp -> IdSet.union vs (assigned_vars exp))
          IdSet.empty es in
      let assigns = isubst_minus_set assigns assigned_in in
      let es' = List.map (fun e -> fst (const_prop_exp substs assigns e)) es in
      es',assigns
    in
    let non_det_exp_2 e1 e2 =
       let assigned_in_e12 = IdSet.union (assigned_vars e1) (assigned_vars e2) in
       let assigns = isubst_minus_set assigns assigned_in_e12 in
       let e1',_ = const_prop_exp substs assigns e1 in
       let e2',_ = const_prop_exp substs assigns e2 in
       e1',e2',assigns
    in
    let non_det_exp_3 e1 e2 e3 =
       let assigned_in_e12 = IdSet.union (assigned_vars e1) (assigned_vars e2) in
       let assigned_in_e123 = IdSet.union assigned_in_e12 (assigned_vars e3) in
       let assigns = isubst_minus_set assigns assigned_in_e123 in
       let e1',_ = const_prop_exp substs assigns e1 in
       let e2',_ = const_prop_exp substs assigns e2 in
       let e3',_ = const_prop_exp substs assigns e3 in
       e1',e2',e3',assigns
    in
    let non_det_exp_4 e1 e2 e3 e4 =
       let assigned_in_e12 = IdSet.union (assigned_vars e1) (assigned_vars e2) in
       let assigned_in_e123 = IdSet.union assigned_in_e12 (assigned_vars e3) in
       let assigned_in_e1234 = IdSet.union assigned_in_e123 (assigned_vars e4) in
       let assigns = isubst_minus_set assigns assigned_in_e1234 in
       let e1',_ = const_prop_exp substs assigns e1 in
       let e2',_ = const_prop_exp substs assigns e2 in
       let e3',_ = const_prop_exp substs assigns e3 in
       let e4',_ = const_prop_exp substs assigns e4 in
       e1',e2',e3',e4',assigns
    in
    let re e assigns = E_aux (e,(l,annot)),assigns in
    match e with
      (* TODO: are there more circumstances in which we should get rid of these? *)
    | E_block [e] -> const_prop_exp substs assigns e
    | E_block es ->
       let es',assigns = threaded_map (const_prop_exp substs) assigns es in
       re (E_block es') assigns
    | E_nondet es ->
       let es',assigns = non_det_exp_list es in
       re (E_nondet es') assigns
    | E_id id ->
       let env = Type_check.env_of_annot (l, annot) in
       (try
         match Env.lookup_id id env with
         | Local (Immutable,_) -> Bindings.find id (fst substs)
         | Local (Mutable,_)   -> Bindings.find id assigns
         | _ -> exp
       with Not_found -> exp),assigns
    | E_lit _
    | E_sizeof _
    | E_constraint _
      -> exp,assigns
    | E_cast (t,e') ->
       let e'',assigns = const_prop_exp substs assigns e' in
       if is_value e''
       then reduce_cast t e'' l annot, assigns
       else re (E_cast (t, e'')) assigns
    | E_app (id,es) ->
       let es',assigns = non_det_exp_list es in
       let env = Type_check.env_of_annot (l, annot) in
       (match try_app (l,annot) (id,es') with
       | None ->
          (match const_prop_try_fn l env (id,es') with
          | None -> re (E_app (id,es')) assigns
          | Some r -> r,assigns)
       | Some r -> r,assigns)
    | E_tuple es ->
       let es',assigns = non_det_exp_list es in
       re (E_tuple es') assigns
    | E_if (e1,e2,e3) ->
       let e1',assigns = const_prop_exp substs assigns e1 in
       let e1_no_casts = drop_casts e1' in
       (match e1_no_casts with
       | E_aux (E_lit (L_aux ((L_true|L_false) as lit ,_)),_) ->
          (match lit with
          | L_true -> const_prop_exp substs assigns e2
          |  _     -> const_prop_exp substs assigns e3)
       | _ ->
          (* If the guard is an equality check, propagate the value. *)
          let env1 = env_of e1_no_casts in
          let is_equal id =
            List.exists (fun id' -> Id.compare id id' == 0)
              (Env.get_overloads (Id_aux (DeIid "==", Parse_ast.Unknown))
                 env1)
          in
          let substs_true =
            match e1_no_casts with
            | E_aux (E_app (id, [E_aux (E_id var,_); vl]),_)
            | E_aux (E_app (id, [vl; E_aux (E_id var,_)]),_)
                when is_equal id ->
               if is_value vl then
                 (match Env.lookup_id var env1 with
                 | Local (Immutable,_) -> Bindings.add var vl (fst substs),snd substs
                 | _ -> substs)
               else substs
            | _ -> substs
          in
          (* Discard impossible branches *)
          if is_env_inconsistent (env_of e2) (snd substs) then
            const_prop_exp substs assigns e3
          else if is_env_inconsistent (env_of e3) (snd substs) then
            const_prop_exp substs_true assigns e2
          else
            let e2',assigns2 = const_prop_exp substs_true assigns e2 in
            let e3',assigns3 = const_prop_exp substs assigns e3 in
            let assigns = isubst_minus_set assigns (assigned_vars e2) in
            let assigns = isubst_minus_set assigns (assigned_vars e3) in
            re (E_if (e1',e2',e3')) assigns)
    | E_for (id,e1,e2,e3,ord,e4) ->
       (* Treat e1, e2 and e3 (from, to and by) as a non-det tuple *)
       let e1',e2',e3',assigns = non_det_exp_3 e1 e2 e3 in
       let assigns = isubst_minus_set assigns (assigned_vars e4) in
       let e4',_ = const_prop_exp (Bindings.remove id (fst substs),snd substs) assigns e4 in
       re (E_for (id,e1',e2',e3',ord,e4')) assigns
    | E_loop (loop,e1,e2) ->
       let assigns = isubst_minus_set assigns (IdSet.union (assigned_vars e1) (assigned_vars e2)) in
       let e1',_ = const_prop_exp substs assigns e1 in
       let e2',_ = const_prop_exp substs assigns e2 in
       re (E_loop (loop,e1',e2')) assigns
    | E_vector es ->
       let es',assigns = non_det_exp_list es in
       begin
         match construct_lit_vector es' with
         | None -> re (E_vector es') assigns
         | Some lit -> re (E_lit lit) assigns
       end
    | E_vector_access (e1,e2) ->
       let e1',e2',assigns = non_det_exp_2 e1 e2 in
       re (E_vector_access (e1',e2')) assigns
    | E_vector_subrange (e1,e2,e3) ->
       let e1',e2',e3',assigns = non_det_exp_3 e1 e2 e3 in
       re (E_vector_subrange (e1',e2',e3')) assigns
    | E_vector_update (e1,e2,e3) ->
       let e1',e2',e3',assigns = non_det_exp_3 e1 e2 e3 in
       re (E_vector_update (e1',e2',e3')) assigns
    | E_vector_update_subrange (e1,e2,e3,e4) ->
       let e1',e2',e3',e4',assigns = non_det_exp_4 e1 e2 e3 e4 in
       re (E_vector_update_subrange (e1',e2',e3',e4')) assigns
    | E_vector_append (e1,e2) ->
       let e1',e2',assigns = non_det_exp_2 e1 e2 in
       re (E_vector_append (e1',e2')) assigns
    | E_list es ->
       let es',assigns = non_det_exp_list es in
       re (E_list es') assigns
    | E_cons (e1,e2) ->
       let e1',e2',assigns = non_det_exp_2 e1 e2 in
       re (E_cons (e1',e2')) assigns
    | E_record fes ->
       let assigned_in_fes = assigned_vars_in_fexps fes in
       let assigns = isubst_minus_set assigns assigned_in_fes in
       re (E_record (const_prop_fexps substs assigns fes)) assigns
    | E_record_update (e,fes) ->
       let assigned_in = IdSet.union (assigned_vars_in_fexps fes) (assigned_vars e) in
       let assigns = isubst_minus_set assigns assigned_in in
       let e',_ = const_prop_exp substs assigns e in
       re (E_record_update (e', const_prop_fexps substs assigns fes)) assigns
    | E_field (e,id) ->
       let e',assigns = const_prop_exp substs assigns e in
       re (E_field (e',id)) assigns
    | E_case (e,cases) ->
       let e',assigns = const_prop_exp substs assigns e in
       (match can_match e' cases substs assigns with
       | None ->
          let assigned_in =
            List.fold_left (fun vs pe -> IdSet.union vs (assigned_vars_in_pexp pe))
              IdSet.empty cases
          in
          let assigns' = isubst_minus_set assigns assigned_in in
          re (E_case (e', List.map (const_prop_pexp substs assigns) cases)) assigns'
       | Some (E_aux (_,(_,annot')) as exp,newbindings,kbindings) ->
          let exp = nexp_subst_exp (kbindings_from_list kbindings) exp in
          let newbindings_env = bindings_from_list newbindings in
          let substs' = bindings_union (fst substs) newbindings_env, snd substs in
          const_prop_exp substs' assigns exp)
    | E_let (lb,e2) ->
       begin
         match lb with
         | LB_aux (LB_val (p,e), annot) ->
            let e',assigns = const_prop_exp substs assigns e in
            let substs' = remove_bound substs p in
            let plain () =
              let e2',assigns = const_prop_exp substs' assigns e2 in
              re (E_let (LB_aux (LB_val (p,e'), annot),
                         e2')) assigns in
            if is_value e' && not (is_value e) then
              match can_match e' [Pat_aux (Pat_exp (p,e2),(Unknown,empty_tannot))] substs assigns with
              | None -> plain ()
              | Some (e'',bindings,kbindings) ->
                 let e'' = nexp_subst_exp (kbindings_from_list kbindings) e'' in
                 let bindings = bindings_from_list bindings in
                 let substs'' = bindings_union (fst substs') bindings, snd substs' in
                 const_prop_exp substs'' assigns e''
            else plain ()
       end
    (* TODO maybe - tuple assignments *)
    | E_assign (le,e) ->
       let env = Type_check.env_of_annot (l, annot) in
       let assigned_in = IdSet.union (assigned_vars_in_lexp le) (assigned_vars e) in
       let assigns = isubst_minus_set assigns assigned_in in
       let le',idopt = const_prop_lexp substs assigns le in
       let e',_ = const_prop_exp substs assigns e in
       let assigns =
         match idopt with
         | Some id ->
            begin
              match Env.lookup_id id env with
              | Local (Mutable,_) | Unbound ->
                 if is_value e' && not (IdSet.mem id ref_vars)
                 then Bindings.add id (keep_undef_typ e') assigns
                 else Bindings.remove id assigns
              | _ -> assigns
            end
         | None -> assigns
       in
       re (E_assign (le', e')) assigns
    | E_exit e ->
       let e',_ = const_prop_exp substs assigns e in
       re (E_exit e') Bindings.empty
    | E_ref id -> re (E_ref id) Bindings.empty
    | E_throw e ->
       let e',_ = const_prop_exp substs assigns e in
       re (E_throw e') Bindings.empty
    | E_try (e,cases) ->
       (* TODO: try and preserve *any* assignment info *)
       let e',_ = const_prop_exp substs assigns e in
       re (E_case (e', List.map (const_prop_pexp substs Bindings.empty) cases)) Bindings.empty
    | E_return e ->
       let e',_ = const_prop_exp substs assigns e in
       re (E_return e') Bindings.empty
    | E_assert (e1,e2) ->
       let e1',e2',assigns = non_det_exp_2 e1 e2 in
       re (E_assert (e1',e2')) assigns
  
    | E_app_infix _
    | E_var _
    | E_internal_plet _
    | E_internal_return _
    | E_internal_value _
      -> raise (Reporting.err_unreachable l __POS__
                  ("Unexpected expression encountered in monomorphisation: " ^ string_of_exp exp))
  and const_prop_fexps substs assigns fes =
    List.map (const_prop_fexp substs assigns) fes
  and const_prop_fexp substs assigns (FE_aux (FE_Fexp (id,e), annot)) =
    FE_aux (FE_Fexp (id,fst (const_prop_exp substs assigns e)),annot)
  and const_prop_pexp substs assigns = function
    | (Pat_aux (Pat_exp (p,e),l)) ->
       Pat_aux (Pat_exp (p,fst (const_prop_exp (remove_bound substs p) assigns e)),l)
    | (Pat_aux (Pat_when (p,e1,e2),l)) ->
       let substs' = remove_bound substs p in
       let e1',assigns = const_prop_exp substs' assigns e1 in
       Pat_aux (Pat_when (p, e1', fst (const_prop_exp substs' assigns e2)),l)
  and const_prop_lexp substs assigns ((LEXP_aux (e,annot)) as le) =
    let re e = LEXP_aux (e,annot), None in
    match e with
    | LEXP_id id (* shouldn't end up substituting here *)
    | LEXP_cast (_,id)
      -> le, Some id
    | LEXP_memory (id,es) ->
       re (LEXP_memory (id,List.map (fun e -> fst (const_prop_exp substs assigns e)) es)) (* or here *)
    | LEXP_tup les -> re (LEXP_tup (List.map (fun le -> fst (const_prop_lexp substs assigns le)) les))
    | LEXP_vector (le,e) -> re (LEXP_vector (fst (const_prop_lexp substs assigns le), fst (const_prop_exp substs assigns e)))
    | LEXP_vector_range (le,e1,e2) ->
       re (LEXP_vector_range (fst (const_prop_lexp substs assigns le),
                              fst (const_prop_exp substs assigns e1),
                              fst (const_prop_exp substs assigns e2)))
    | LEXP_vector_concat les -> re (LEXP_vector_concat (List.map (fun le -> fst (const_prop_lexp substs assigns le)) les))
    | LEXP_field (le,id) -> re (LEXP_field (fst (const_prop_lexp substs assigns le), id))
    | LEXP_deref e ->
       re (LEXP_deref (fst (const_prop_exp substs assigns e)))
  (* Reduce a function when
     1. all arguments are values,
     2. the function is pure,
     3. the result is a value
     (and 4. the function is not scattered, but that's not terribly important)
     to try and keep execution time and the results managable.
  *)
  and const_prop_try_fn l env (id,args) =
    if not (List.for_all is_value args) then
      None
    else
      let (tq,typ) = Env.get_val_spec_orig id env in
      let eff = match typ with
        | Typ_aux (Typ_fn (_,_,eff),_) -> Some eff
        | _ -> None
      in
      let Defs ds = defs in
      match eff, list_extract (function
      | (DEF_fundef (FD_aux (FD_function (_,_,eff,((FCL_aux (FCL_Funcl (id',_),_))::_ as fcls)),_)))
        -> if Id.compare id id' = 0 then Some fcls else None
      | _ -> None) ds with
      | None,_ | _,None -> None
      | Some eff,_ when not (is_pure eff) -> None
      | Some _,Some fcls ->
         let arg = match args with
           | [] -> E_aux (E_lit (L_aux (L_unit,Generated l)),(Generated l,empty_tannot))
           | [e] -> e
           | _ -> E_aux (E_tuple args,(Generated l,empty_tannot)) in
         let cases = List.map (function
           | FCL_aux (FCL_Funcl (_,pexp), ann) -> pexp)
           fcls in
         match can_match_with_env env arg cases (Bindings.empty,KBindings.empty) Bindings.empty with
         | Some (exp,bindings,kbindings) ->
            let substs = bindings_from_list bindings, kbindings_from_list kbindings in
            let result,_ = const_prop_exp substs Bindings.empty exp in
            let result = match result with
              | E_aux (E_return e,_) -> e
              | _ -> result
            in
            if is_value result then Some result else None
         | None -> None
  
  and can_match_with_env env (E_aux (e,(l,annot)) as exp0) cases (substs,ksubsts) assigns =
    let rec findpat_generic check_pat description assigns = function
      | [] -> (Reporting.print_err l "Monomorphisation"
                 ("Failed to find a case for " ^ description); None)
      | [Pat_aux (Pat_exp (P_aux (P_wild,_),exp),_)] -> Some (exp,[],[])
      | (Pat_aux (Pat_exp (P_aux (P_typ (_,p),_),exp),ann))::tl ->
         findpat_generic check_pat description assigns ((Pat_aux (Pat_exp (p,exp),ann))::tl)
      | (Pat_aux (Pat_exp (P_aux (P_id id',_),exp),_))::tlx
          when pat_id_is_variable env id' ->
         Some (exp, [(id', exp0)], [])
      | (Pat_aux (Pat_when (P_aux (P_id id',_),guard,exp),_))::tl
          when pat_id_is_variable env id' -> begin
            let substs = Bindings.add id' exp0 substs, ksubsts in
            let (E_aux (guard,_)),assigns = const_prop_exp substs assigns guard in
            match guard with
            | E_lit (L_aux (L_true,_)) -> Some (exp,[(id',exp0)],[])
            | E_lit (L_aux (L_false,_)) -> findpat_generic check_pat description assigns tl
            | _ -> None
          end
      | (Pat_aux (Pat_when (p,guard,exp),_))::tl -> begin
        match check_pat p with
        | DoesNotMatch -> findpat_generic check_pat description assigns tl
        | DoesMatch (vsubst,ksubst) -> begin
          let guard = nexp_subst_exp (kbindings_from_list ksubst) guard in
          let substs = bindings_union substs (bindings_from_list vsubst),
                       kbindings_union ksubsts (kbindings_from_list ksubst) in
          let (E_aux (guard,_)),assigns = const_prop_exp substs assigns guard in
          match guard with
          | E_lit (L_aux (L_true,_)) -> Some (exp,vsubst,ksubst)
          | E_lit (L_aux (L_false,_)) -> findpat_generic check_pat description assigns tl
          | _ -> None
        end
        | GiveUp -> None
      end
      | (Pat_aux (Pat_exp (p,exp),_))::tl ->
         match check_pat p with
         | DoesNotMatch -> findpat_generic check_pat description assigns tl
         | DoesMatch (subst,ksubst) -> Some (exp,subst,ksubst)
         | GiveUp -> None
    in
    match e with
    | E_id id ->
       (match Env.lookup_id id env with
       | Enum _ ->
          let checkpat = function
            | P_aux (P_id id',_)
            | P_aux (P_app (id',[]),_) ->
               if Id.compare id id' = 0 then DoesMatch ([],[]) else DoesNotMatch
            | P_aux (_,(l',_)) ->
               (Reporting.print_err l' "Monomorphisation"
                  "Unexpected kind of pattern for enumeration"; GiveUp)
          in findpat_generic checkpat (string_of_id id) assigns cases
       | _ -> None)
    | E_lit (L_aux (lit_e, lit_l)) ->
       let checkpat = function
         | P_aux (P_lit (L_aux (lit_p, _)),_) ->
            if lit_match (lit_e,lit_p) then DoesMatch ([],[]) else DoesNotMatch
         | P_aux (P_var (P_aux (P_id id,p_id_annot), TP_aux (TP_var kid, _)),_) ->
            begin
              match lit_e with
              | L_num i ->
                 DoesMatch ([id, E_aux (e,(l,annot))],
                            [kid,Nexp_aux (Nexp_constant i,Unknown)])
              (* For undefined we fix the type-level size (because there's no good
                 way to construct an undefined size), but leave the term as undefined
                 to make the meaning clear. *)
              | L_undef ->
                 let nexp = fabricate_nexp l annot in
                 let typ = subst_kids_typ (KBindings.singleton kid nexp) (typ_of_annot p_id_annot) in
                 DoesMatch ([id, E_aux (E_cast (typ,E_aux (e,(l,empty_tannot))),(l,empty_tannot))],
                            [kid,nexp])
              | _ ->
                 (Reporting.print_err lit_l "Monomorphisation"
                    "Unexpected kind of literal for var match"; GiveUp)
            end
         | P_aux (_,(l',_)) ->
            (Reporting.print_err l' "Monomorphisation"
               "Unexpected kind of pattern for literal"; GiveUp)
       in findpat_generic checkpat "literal" assigns cases
    | E_vector es when List.for_all (function (E_aux (E_lit _,_)) -> true | _ -> false) es ->
       let checkpat = function
         | P_aux (P_vector ps,_) ->
            let matches = List.map2 (fun e p ->
              match e, p with
              | E_aux (E_lit (L_aux (lit,_)),_), P_aux (P_lit (L_aux (lit',_)),_) ->
                 if lit_match (lit,lit') then DoesMatch ([],[]) else DoesNotMatch
              | E_aux (E_lit l,_), P_aux (P_id var,_) when pat_id_is_variable env var ->
                 DoesMatch ([var, e],[])
              | _ -> GiveUp) es ps in
            let final = List.fold_left (fun acc m -> match acc, m with
              | _, GiveUp -> GiveUp
              | GiveUp, _ -> GiveUp
              | DoesMatch (sub,ksub), DoesMatch(sub',ksub') -> DoesMatch(sub@sub',ksub@ksub')
              | _ -> DoesNotMatch) (DoesMatch ([],[])) matches in
            (match final with
            | GiveUp ->
               (Reporting.print_err l "Monomorphisation"
                  "Unexpected kind of pattern for vector literal"; GiveUp)
            | _ -> final)
         | _ ->
            (Reporting.print_err l "Monomorphisation"
               "Unexpected kind of pattern for vector literal"; GiveUp)
       in findpat_generic checkpat "vector literal" assigns cases
  
    | E_cast (undef_typ, (E_aux (E_lit (L_aux (L_undef, lit_l)),_) as e_undef)) ->
       let checkpat = function
         | P_aux (P_lit (L_aux (lit_p, _)),_) -> DoesNotMatch
         | P_aux (P_var (P_aux (P_id id,p_id_annot), TP_aux (TP_var kid, _)),_) ->
              (* For undefined we fix the type-level size (because there's no good
                 way to construct an undefined size), but leave the term as undefined
                 to make the meaning clear. *)
            let nexp = fabricate_nexp l annot in
            let kids = equal_kids (env_of_annot p_id_annot) kid in
            let ksubst = KidSet.fold (fun k b -> KBindings.add k nexp b) kids KBindings.empty in
            let typ = subst_kids_typ ksubst (typ_of_annot p_id_annot) in
            DoesMatch ([id, E_aux (E_cast (typ,e_undef),(l,empty_tannot))],
                       KBindings.bindings ksubst)
         | P_aux (_,(l',_)) ->
            (Reporting.print_err l' "Monomorphisation"
               "Unexpected kind of pattern for literal"; GiveUp)
       in findpat_generic checkpat "literal" assigns cases
    | _ -> None
  
  and can_match exp =
    let env = Type_check.env_of exp in
    can_match_with_env env exp

in (const_prop_exp, const_prop_pexp)

let const_prop d r = fst (const_props d r)
let const_prop_pexp d r = snd (const_props d r)

let referenced_vars exp =
  let open Rewriter in
  fst (fold_exp
         { (compute_exp_alg IdSet.empty IdSet.union) with
           e_ref = (fun id -> IdSet.singleton id, E_ref id) } exp)

(* This is intended to remove impossible cases when a type-level constant has
   been used to fix a property of the architecture.  In particular, the current
   version of the RISC-V model uses constructs like

   match (width, sizeof(xlen)) {
     (BYTE, _)    => ...
     ...
     (DOUBLE, 64) => ...
   };

   and the type checker will replace the sizeof with the literal 32 or 64.  This
   pass will then remove the DOUBLE case.

   It would be nice to have the full constant propagation above do this kind of
   thing too...
*)

let remove_impossible_int_cases _ =

  let must_keep_case exp (Pat_aux ((Pat_exp (p,_) | Pat_when (p,_,_)),_)) =
    let rec aux (E_aux (exp,_)) (P_aux (p,_)) =
      match exp, p with
      | E_tuple exps, P_tup ps -> List.for_all2 aux exps ps
      | E_lit (L_aux (lit,_)), P_lit (L_aux (lit',_)) -> lit_match (lit, lit')
      | _ -> true
    in aux exp p
  in
  let e_case (exp,cases) =
    E_case (exp, List.filter (must_keep_case exp) cases)
  in
  let e_if (cond, e_then, e_else) =
    match destruct_atom_bool (env_of cond) (typ_of cond) with
    | Some nc ->
       if prove __POS__ (env_of cond) nc then unaux_exp e_then else
       if prove __POS__ (env_of cond) (nc_not nc) then unaux_exp e_else else
       E_if (cond, e_then, e_else)
    | _ -> E_if (cond, e_then, e_else)
  in
  let open Rewriter in
  let rewrite_exp _ = fold_exp { id_exp_alg with e_case = e_case; e_if = e_if } in
  rewrite_defs_base { rewriters_base with rewrite_exp = rewrite_exp }