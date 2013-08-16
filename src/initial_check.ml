open Type_internal
open Ast

type kind = Type_internal.kind
type typ = Type_internal.t

type envs = Nameset.t * kind Envmap.t * t Envmap.t
type 'a envs_out = 'a * envs

let id_to_string (Id_aux(id,l)) =
  match id with | Id(x) | DeIid(x) -> x

(*placeholder, write in type_internal*)
let kind_to_string _ = " kind pp place holder "

let typquant_to_quantkinds k_env typquant = 
  match typquant with
  | TypQ_aux(tq,_) ->
    (match tq with
    | TypQ_no_forall -> []
    | TypQ_tq(qlist) ->
      List.fold_right
        (fun (QI_aux(qi,_)) rst ->
          match qi with
          | QI_const _ -> rst
          | QI_id(ki) -> begin
            match ki with 
            | KOpt_aux(KOpt_none(id),l) | KOpt_aux(KOpt_kind(_,id),l) -> 
              (match Envmap.apply k_env (id_to_string id) with
              | Some(typ) -> typ::rst
              | None -> raise (Reporting_basic.err_unreachable l "Envmap didn't get an entry during typschm processing"))
          end)
        qlist
        [])

let typ_error l msg opt_id opt_kind =
  raise (Reporting_basic.err_typ 
           l
           (msg ^
              (match opt_id, opt_kind with
              | Some(id),Some(kind) -> (id_to_string id) ^ " of " ^ (kind_to_string kind)
              | Some(id),None -> ": " ^ (id_to_string id)
              | None,Some(kind) -> " " ^ (kind_to_string kind)
              | None,None -> "")))
                
let to_ast_id (Parse_ast.Id_aux(id,l)) =
    Id_aux( (match id with
             | Parse_ast.Id(x) -> Id(x)
             | Parse_ast.DeIid(x) -> DeIid(x)) , l)

let to_ast_base_kind (Parse_ast.BK_aux(k,l')) =
  match k with
  | Parse_ast.BK_type -> BK_aux(BK_type,l'), { k = K_Typ}
  | Parse_ast.BK_nat -> BK_aux(BK_nat,l'), { k = K_Nat }
  | Parse_ast.BK_order -> BK_aux(BK_order,l'), { k = K_Ord }
  | Parse_ast.BK_effects -> BK_aux(BK_effects,l'), { k = K_Efct }

let to_ast_kind (k_env : kind Envmap.t) (Parse_ast.K_aux(Parse_ast.K_kind(klst),l)) : (Ast.kind * kind) =
  match klst with
  | [] -> raise (Reporting_basic.err_unreachable l "Kind with empty kindlist encountered")
  | [k] -> let k_ast,k_typ = to_ast_base_kind k in
           K_aux(K_kind([k_ast]),l), k_typ
  | ks -> let k_pairs = List.map to_ast_base_kind ks in
          let reverse_typs = List.rev (List.map snd k_pairs) in
          let ret,args = List.hd reverse_typs, List.rev (List.tl reverse_typs) in
          match ret.k with
          | K_Typ -> K_aux(K_kind(List.map fst k_pairs), l), { k = K_Lam(args,ret) }
          | _ -> typ_error l "Type constructor must have an -> kind ending in Type" None None

let rec to_ast_typ (k_env : kind Envmap.t) (t: Parse_ast.atyp) : Ast.typ =
  match t with
  | Parse_ast.ATyp_aux(t,l) ->
    Typ_aux( (match t with 
              | Parse_ast.ATyp_id(id) -> 
                let id = to_ast_id id in
                let mk = Envmap.apply k_env (id_to_string id) in
                (match mk with
                | Some(k) -> (match k.k with
                              | K_Typ -> Typ_var id
                              | K_infer -> k.k <- K_Typ; Typ_var id
                              | _ -> typ_error l "Required a variable with kind Type, encountered " (Some id) (Some k))
                | None -> typ_error l "Encountered an unbound variable" (Some id) None)
              | Parse_ast.ATyp_wild -> Typ_wild
              | Parse_ast.ATyp_fn(arg,ret,efct) -> Typ_fn( (to_ast_typ k_env arg),
                                                           (to_ast_typ k_env ret),
                                                           (to_ast_effects k_env efct))
              | Parse_ast.ATyp_tup(typs) -> Typ_tup( List.map (to_ast_typ k_env) typs)
              | Parse_ast.ATyp_app(pid,typs) ->
                  let id = to_ast_id pid in 
                  let k = Envmap.apply k_env (id_to_string id) in
                  (match k with 
                  | Some({k = K_Lam(args,t)}) -> Typ_app(id,(List.map2 (fun k a -> (to_ast_typ_arg k_env k a)) args typs))
                  | None -> typ_error l "Required a type constructor, encountered an unbound variable" (Some id) None
                  | _ -> typ_error l "Required a type constructor, encountered a base kind variable" (Some id) None)
              | _ -> typ_error l "Required an item of kind Type, encountered an illegal form for this kind" None None
    ), l)

and to_ast_nexp (k_env : kind Envmap.t) (n: Parse_ast.atyp) : Ast.nexp =
  match n with
  | Parse_ast.ATyp_aux(t,l) ->
    (match t with
    | Parse_ast.ATyp_id(id) ->                 
                let id = to_ast_id id in
                let mk = Envmap.apply k_env (id_to_string id) in
                (match mk with
                | Some(k) -> Nexp_aux((match k.k with
                                      | K_Nat -> Nexp_id id
                                      | K_infer -> k.k <- K_Nat; Nexp_id id
                                      | _ -> typ_error l "Required a variable with kind Nat, encountered " (Some id) (Some k)),l)
                | None -> typ_error l "Encountered an unbound variable" (Some id) None)
    | Parse_ast.ATyp_constant(i) -> Nexp_aux(Nexp_constant(i),l)
    | Parse_ast.ATyp_sum(t1,t2) ->
      let n1 = to_ast_nexp k_env t1 in
      let n2 = to_ast_nexp k_env t2 in
      Nexp_aux(Nexp_sum(n1,n2),l)
    | Parse_ast.ATyp_exp(t1) -> Nexp_aux(Nexp_exp(to_ast_nexp k_env t1),l)
    | Parse_ast.ATyp_tup(typs) ->
      let rec times_loop (typs : Parse_ast.atyp list) (one_ok : bool) : nexp =
        (match typs,one_ok with
        | [],_ | [_],false -> raise (Reporting_basic.err_unreachable l "to_ast_nexp has ATyp_tup with empty list or list with one element")
        | [t],true -> to_ast_nexp k_env t
        | (t1::typs),_ -> let n1 = to_ast_nexp k_env t1 in
                          let n2 = times_loop typs true in 
                          (Nexp_aux((Nexp_times(n1,n2)),l)))  (*TODO This needs just a portion of the l, think about adding a way to split*)
      in
      times_loop typs false
    | _ -> typ_error l "Requred an item of kind Nat, encountered an illegal form for this kind" None None)
    
and to_ast_order (k_env : kind Envmap.t) (o: Parse_ast.atyp) : Ast.order =
  match o with
  | Parse_ast.ATyp_aux(t,l) ->
    Ord_aux( (match t with
               | Parse_ast.ATyp_id(id) -> 
                let id = to_ast_id id in
                let mk = Envmap.apply k_env (id_to_string id) in
                (match mk with
                | Some(k) -> (match k.k with
                              | K_Ord -> Ord_id id
                              | K_infer -> k.k <- K_Ord; Ord_id id
                              | _ -> typ_error l "Required a variable with kind Order, encountered " (Some id) (Some k))
                | None -> typ_error l "Encountered an unbound variable" (Some id) None)
               | Parse_ast.ATyp_inc -> Ord_inc
               | Parse_ast.ATyp_dec -> Ord_dec
               | _ -> typ_error l "Requred an item of kind Order, encountered an illegal form for this kind" None None
    ), l)

and to_ast_effects (k_env : kind Envmap.t) (e : Parse_ast.atyp) : Ast.effects =
  match e with
  | Parse_ast.ATyp_aux(t,l) ->
    Effects_aux( (match t with
               | Parse_ast.ATyp_efid(id) ->  
                let id = to_ast_id id in
                let mk = Envmap.apply k_env (id_to_string id) in
                (match mk with
                | Some(k) -> (match k.k with
                              | K_Efct -> Effects_var id
                              | K_infer -> k.k <- K_Efct; Effects_var id
                              | _ -> typ_error l "Required a variable with kind Effect, encountered " (Some id) (Some k))
                | None -> typ_error l "Encountered an unbound variable" (Some id) None)
               | Parse_ast.ATyp_set(effects) ->
                 Effects_set( List.map 
                             (fun efct -> match efct with
                             | Parse_ast.Effect_aux(e,l) ->
                               Effect_aux((match e with 
                               | Parse_ast.Effect_rreg -> Effect_rreg
                               | Parse_ast.Effect_wreg -> Effect_wreg
                               | Parse_ast.Effect_rmem -> Effect_rmem
                               | Parse_ast.Effect_wmem -> Effect_wmem
                               | Parse_ast.Effect_undef -> Effect_undef
                               | Parse_ast.Effect_unspec -> Effect_unspec
                               | Parse_ast.Effect_nondet -> Effect_nondet),l))
                             effects)
               | _ -> typ_error l "Required an item of kind Effects, encountered an illegal form for this kind" None None
    ), l)

and to_ast_typ_arg (k_env : kind Envmap.t) (kind : kind) (arg : Parse_ast.atyp) : Ast.typ_arg =
  let l = (match arg with Parse_ast.ATyp_aux(_,l) -> l) in
  Typ_arg_aux (  
    (match kind.k with 
    | K_Typ -> Typ_arg_typ (to_ast_typ k_env arg)
    | K_Nat  -> Typ_arg_nexp (to_ast_nexp k_env arg)
    | K_Ord -> Typ_arg_order (to_ast_order k_env arg)
    | K_Efct -> Typ_arg_effects (to_ast_effects k_env arg)
    | _ -> raise (Reporting_basic.err_unreachable l "To_ast_typ_arg received Lam kind or infer kind")),
    l)

let to_ast_nexp_constraint (k_env : kind Envmap.t) (c : Parse_ast.nexp_constraint) : nexp_constraint =
  match c with 
  | Parse_ast.NC_aux(nc,l) ->
    NC_aux( (match nc with
             | Parse_ast.NC_fixed(t1,t2) -> 
               let n1 = to_ast_nexp k_env t1 in
               let n2 = to_ast_nexp k_env t2 in
               NC_fixed(n1,n2)
             | Parse_ast.NC_bounded_ge(t1,t2) ->
               let n1 = to_ast_nexp k_env t1 in
               let n2 = to_ast_nexp k_env t2 in
               NC_bounded_ge(n1,n2)
             | Parse_ast.NC_bounded_le(t1,t2) ->
               let n1 = to_ast_nexp k_env t1 in
               let n2 = to_ast_nexp k_env t2 in
               NC_bounded_le(n1,n2)
             | Parse_ast.NC_nat_set_bounded(id,bounds) ->
               NC_nat_set_bounded(to_ast_id id, bounds)
    ), l)               

let to_ast_typquant (k_env: kind Envmap.t) (tq : Parse_ast.typquant) : typquant * kind Envmap.t =
  let opt_kind_to_ast k_env local_names (Parse_ast.KOpt_aux(ki,l)) =
    let id, key, kind, ktyp =
      match ki with
      | Parse_ast.KOpt_none(id) ->
	let id = to_ast_id id in
	let key = id_to_string id in
	let kind,ktyp = if (Envmap.in_dom key k_env) then None,(Envmap.apply k_env key) else None,(Some{ k = K_infer }) in
	id,key,kind, ktyp
      | Parse_ast.KOpt_kind(k,id) ->
	let id = to_ast_id id in
	let key = id_to_string id in
	let kind,ktyp = to_ast_kind k_env k in
	id,key,Some(kind),Some(ktyp)
    in
    if (Nameset.mem key local_names)
    then typ_error l "Encountered duplicate name in type scheme" (Some id) None
    else 
      let local_names = Nameset.add key local_names in
      let kopt,k_env = (match kind,ktyp with
        | Some(k),Some(kt) -> KOpt_kind(k,id), (Envmap.insert k_env (key,kt))
	| None, Some(kt) -> KOpt_none(id), (Envmap.insert k_env (key,kt))
	| _ -> raise (Reporting_basic.err_unreachable l "Envmap in dom true but apply gives None")) in
      KOpt_aux(kopt,l),k_env,local_names
  in
  match tq with
  | Parse_ast.TypQ_aux(tqa,l) ->
    (match tqa with
    | Parse_ast.TypQ_no_forall -> TypQ_aux(TypQ_no_forall,l), k_env
    | Parse_ast.TypQ_tq(qlist) ->
      let rec to_ast_q_items k_env local_names = function
	| [] -> [],k_env
	| q::qs -> (match q with
	            | Parse_ast.QI_aux(qi,l) ->
		      (match qi with
		      | Parse_ast.QI_const(n_const) -> 
			let c = QI_aux(QI_const(to_ast_nexp_constraint k_env n_const),l) in
			let qis,k_env = to_ast_q_items k_env local_names qs in
			(c::qis),k_env
		      | Parse_ast.QI_id(kid) ->
			let kid,k_env,local_names = opt_kind_to_ast k_env local_names kid in
			let c = QI_aux(QI_id(kid),l) in
			let qis,k_env = to_ast_q_items k_env local_names qs in
			(c::qis),k_env))	
      in
      let lst,k_env = to_ast_q_items k_env Nameset.empty qlist in
      TypQ_aux(TypQ_tq(lst),l), k_env)

let to_ast_typschm (k_env : kind Envmap.t) (tschm : Parse_ast.typschm) : Ast.typschm * kind Envmap.t =
  match tschm with
  | Parse_ast.TypSchm_aux(ts,l) -> 
    (match ts with | Parse_ast.TypSchm_ts(tquant,t) ->
      let tq,k_env = to_ast_typquant k_env tquant in
      let typ = to_ast_typ k_env t in
      TypSchm_aux(TypSchm_ts(tq,typ),l),k_env)

let to_ast_lit (Parse_ast.L_aux(lit,l)) : lit = 
  L_aux(
    (match lit with
    | Parse_ast.L_unit -> L_unit
    | Parse_ast.L_zero -> L_zero
    | Parse_ast.L_one -> L_one
    | Parse_ast.L_true -> L_true
    | Parse_ast.L_false -> L_false
    | Parse_ast.L_num(i) -> L_num(i)
    | Parse_ast.L_hex(h) -> L_hex(h)
    | Parse_ast.L_bin(b) -> L_bin(b)
    | Parse_ast.L_string(s) -> L_string(s))
      ,l)

let rec to_ast_pat (k_env : kind Envmap.t) (Parse_ast.P_aux(pat,l) : Parse_ast.pat) : tannot pat = 
  P_aux(
    (match pat with 
    | Parse_ast.P_lit(lit) -> P_lit(to_ast_lit lit)
    | Parse_ast.P_wild -> P_wild
    | Parse_ast.P_as(pat,id) -> P_as(to_ast_pat k_env pat,to_ast_id id)
    | Parse_ast.P_typ(typ,pat) -> P_typ(to_ast_typ k_env typ,to_ast_pat k_env pat)
    | Parse_ast.P_id(id) -> P_id(to_ast_id id)
    | Parse_ast.P_app(id,pats) -> P_app(to_ast_id id, List.map (to_ast_pat k_env) pats)
    | Parse_ast.P_record(fpats,_) -> P_record(List.map 
                                                (fun (Parse_ast.FP_aux(Parse_ast.FP_Fpat(id,fp),l)) -> FP_aux(FP_Fpat(to_ast_id id, to_ast_pat k_env fp),(l,None)))
                                                fpats, false)
    | Parse_ast.P_vector(pats) -> P_vector(List.map (to_ast_pat k_env) pats)
    | Parse_ast.P_vector_indexed(ipats) -> P_vector_indexed(List.map (fun (i,pat) -> i,to_ast_pat k_env pat) ipats)
    | Parse_ast.P_vector_concat(pats) -> P_vector_concat(List.map (to_ast_pat k_env) pats)
    | Parse_ast.P_tup(pats) -> P_tup(List.map (to_ast_pat k_env) pats)
    | Parse_ast.P_list(pats) -> P_list(List.map (to_ast_pat k_env) pats)
    ), (l,None))


let rec to_ast_letbind (k_env : kind Envmap.t) (Parse_ast.LB_aux(lb,l) : Parse_ast.letbind) : tannot letbind =
  LB_aux(
    (match lb with
    | Parse_ast.LB_val_explicit(typschm,pat,exp) ->
      let typsch, k_env = to_ast_typschm k_env typschm in
      LB_val_explicit(typsch,to_ast_pat k_env pat, to_ast_exp k_env exp)
    | Parse_ast.LB_val_implicit(pat,exp) ->
      LB_val_implicit(to_ast_pat k_env pat, to_ast_exp k_env exp)
    ), (l,None))

and to_ast_exp (k_env : kind Envmap.t) (Parse_ast.E_aux(exp,l) : Parse_ast.exp) : tannot exp = 
  E_aux(
    (match exp with
    | Parse_ast.E_block(exps) -> 
      (match to_ast_fexps false k_env exps with
      | Some(fexps) -> E_record(fexps)
      | None -> E_block(List.map (to_ast_exp k_env) exps))
    | Parse_ast.E_id(id) -> E_id(to_ast_id id)
    | Parse_ast.E_lit(lit) -> E_lit(to_ast_lit lit)
    | Parse_ast.E_cast(typ,exp) -> E_cast(to_ast_typ k_env typ, to_ast_exp k_env exp)
    | Parse_ast.E_app(f,args) -> E_app(to_ast_exp k_env f, List.map (to_ast_exp k_env) args)
    | Parse_ast.E_app_infix(left,op,right) -> E_app_infix(to_ast_exp k_env left, to_ast_id op, to_ast_exp k_env right)
    | Parse_ast.E_tuple(exps) -> E_tuple(List.map (to_ast_exp k_env) exps)
    | Parse_ast.E_if(e1,e2,e3) -> E_if(to_ast_exp k_env e1, to_ast_exp k_env e2, to_ast_exp k_env e3)
    | Parse_ast.E_vector(exps) -> E_vector(List.map (to_ast_exp k_env) exps)
    | Parse_ast.E_vector_indexed(iexps) -> E_vector_indexed(List.map (fun (i,e) -> (i,to_ast_exp k_env e)) iexps)
    | Parse_ast.E_vector_access(vexp,exp) -> E_vector_access(to_ast_exp k_env vexp, to_ast_exp k_env exp)
    | Parse_ast.E_vector_subrange(vex,exp1,exp2) -> E_vector_subrange(to_ast_exp k_env vex, to_ast_exp k_env exp1, to_ast_exp k_env exp2)
    | Parse_ast.E_vector_update(vex,exp1,exp2) -> E_vector_update(to_ast_exp k_env vex, to_ast_exp k_env exp1, to_ast_exp k_env exp2)
    | Parse_ast.E_vector_update_subrange(vex,e1,e2,e3) -> E_vector_update_subrange(to_ast_exp k_env vex, to_ast_exp k_env e1, to_ast_exp k_env e2, to_ast_exp k_env e3)
    | Parse_ast.E_list(exps) -> E_list(List.map (to_ast_exp k_env) exps)
    | Parse_ast.E_cons(e1,e2) -> E_cons(to_ast_exp k_env e1, to_ast_exp k_env e2)
    | Parse_ast.E_record _ -> raise (Reporting_basic.err_unreachable l "parser generated an E_record")
    | Parse_ast.E_record_update(exp,fexps) -> 
      (match to_ast_fexps true k_env fexps with
      | Some(fexps) -> E_record_update(to_ast_exp k_env exp, fexps)
      | _ -> raise (Reporting_basic.err_unreachable l "to_ast_fexps with true returned none"))
    | Parse_ast.E_field(exp,id) -> E_field(to_ast_exp k_env exp, to_ast_id id)
    | Parse_ast.E_case(exp,pexps) -> E_case(to_ast_exp k_env exp, List.map (to_ast_case k_env) pexps)
    | Parse_ast.E_let(leb,exp) -> E_let(to_ast_letbind k_env leb, to_ast_exp k_env exp)
    | Parse_ast.E_assign(lexp,exp) -> E_assign(to_ast_lexp k_env lexp, to_ast_exp k_env exp)
    ), (l,None))

and to_ast_lexp (k_env : kind Envmap.t) (Parse_ast.E_aux(exp,l) : Parse_ast.exp) : tannot lexp = 
  LEXP_aux(
    (match exp with
    | Parse_ast.E_id(id) -> LEXP_id(to_ast_id id)
    | Parse_ast.E_vector_access(vexp,exp) -> LEXP_vector(to_ast_lexp k_env vexp, to_ast_exp k_env exp)
    | Parse_ast.E_vector_subrange(vexp,exp1,exp2) -> LEXP_vector_range(to_ast_lexp k_env vexp, to_ast_exp k_env exp1, to_ast_exp k_env exp2)
    | Parse_ast.E_field(fexp,id) -> LEXP_field(to_ast_lexp k_env fexp, to_ast_id id)
    | _ -> typ_error l "Only identifiers, vector accesses, vector slices, and fields can be on the lefthand side of an assignment" None None)
      , (l,None))

and to_ast_case (k_env : kind Envmap.t) (Parse_ast.Pat_aux(pex,l) : Parse_ast.pexp) : tannot pexp =
  match pex with 
  | Parse_ast.Pat_exp(pat,exp) -> Pat_aux(Pat_exp(to_ast_pat k_env pat, to_ast_exp k_env exp),(l,None))

and to_ast_fexps (fail_on_error : bool) (k_env : kind Envmap.t) (exps : Parse_ast.exp list) : tannot fexps option =
  match exps with
  | [] -> Some(FES_aux(FES_Fexps([],false), (Parse_ast.Unknown,None)))
  | fexp::exps -> let maybe_fexp,maybe_error = to_ast_record_try k_env fexp in
                  (match maybe_fexp,maybe_error with
                  | Some(fexp),None -> 
                    (match (to_ast_fexps fail_on_error k_env exps) with
                    | Some(FES_aux(FES_Fexps(fexps,_),l)) -> Some(FES_aux(FES_Fexps(fexp::fexps,false),l))
                    | _  -> None)
                  | None,Some(l,msg) -> 
                    if fail_on_error
                    then typ_error l msg None None
                    else None
                  | _ -> None)

and to_ast_record_try (k_env : kind Envmap.t) (Parse_ast.E_aux(exp,l) : Parse_ast.exp) : tannot fexp option * (l * string) option =
  match exp with
  | Parse_ast.E_app_infix(left,op,r) ->
    (match left, op with
    | Parse_ast.E_aux(Parse_ast.E_id(id),li), Parse_ast.Id_aux(Parse_ast.Id("="),leq) ->
      Some(FE_aux(FE_Fexp(to_ast_id id, to_ast_exp k_env r), (l,None))),None
    | Parse_ast.E_aux(_,li) , Parse_ast.Id_aux(Parse_ast.Id("="),leq) ->
      None,Some(li,"Expected an identifier to begin this field assignment")
    | Parse_ast.E_aux(Parse_ast.E_id(id),li), Parse_ast.Id_aux(_,leq) ->
      None,Some(leq,"Expected a field assignment to be identifier = expression")
    | Parse_ast.E_aux(_,li),Parse_ast.Id_aux(_,leq) ->
      None,Some(l,"Expected a field assignment to be identifier = expression"))
  | _ ->
    None,Some(l, "Expected a field assignment to be identifier = expression")
      
let to_ast_default (names, k_env, t_env) (default : Parse_ast.default_typing_spec) : (tannot default_typing_spec) envs_out =
  match default with
  | Parse_ast.DT_aux(df,l) ->
    (match df with 
    | Parse_ast.DT_kind(bk,id) ->
      let k,k_typ = to_ast_base_kind bk in
      let id = to_ast_id id in
      let key = id_to_string id in
      DT_aux(DT_kind(k,id),(l,None)),(names,(Envmap.insert k_env (key,k_typ)),t_env)
    | Parse_ast.DT_typ(typschm,id) ->
      let tps,_ = to_ast_typschm k_env typschm in
      DT_aux(DT_typ(tps,to_ast_id id),(l,None)),(names,k_env,t_env) (* Does t_env need to be updated here in this pass? *)
    )

let to_ast_spec (names,k_env,t_env) (val_:Parse_ast.val_spec) : (tannot val_spec) envs_out =
  match val_ with
  | Parse_ast.VS_aux(vs,l) ->
    (match vs with
    | Parse_ast.VS_val_spec(ts,id) ->
      let typsch,_ = to_ast_typschm k_env ts in
      VS_aux(VS_val_spec(typsch,to_ast_id id),(l,None)),(names,k_env,t_env)) (*Do names and t_env need updating this pass? *)

let to_ast_namescm (Parse_ast.Name_sect_aux(ns,l)) = 
  Name_sect_aux(
    (match ns with
    | Parse_ast.Name_sect_none -> Name_sect_none
    | Parse_ast.Name_sect_some(s) -> Name_sect_some(s)
    ),l)

let rec to_ast_range (Parse_ast.BF_aux(r,l)) = (* TODO add check that ranges are sensible for some definition of sensible *)
  BF_aux(
    (match r with
    | Parse_ast.BF_single(i) -> BF_single(i)
    | Parse_ast.BF_range(i1,i2) -> BF_range(i1,i2)
    | Parse_ast.BF_concat(ir1,ir2) -> BF_concat( to_ast_range ir1, to_ast_range ir2)),
    l)

let to_ast_typedef (names,k_env,t_env) (td:Parse_ast.type_def) : (tannot type_def) envs_out =
  match td with
  | Parse_ast.TD_aux(td,l) ->
  (match td with 
  | Parse_ast.TD_abbrev(id,name_scm_opt,typschm) ->
    let id = to_ast_id id in
    let key = id_to_string id in
    let typschm,_ = to_ast_typschm k_env typschm in
    let td_abrv = TD_aux(TD_abbrev(id,to_ast_namescm name_scm_opt,typschm),(l,None)) in
    let typ = (match typschm with 
      | TypSchm_aux(TypSchm_ts(tq,typ), _) ->
        begin match (typquant_to_quantkinds k_env tq) with
        | [] -> {k = K_Typ}
        | typs -> {k= K_Lam(typs,{k=K_Typ})}
        end) in
    td_abrv,(names,Envmap.insert k_env (key,typ),t_env)
  | Parse_ast.TD_record(id,name_scm_opt,typq,fields,_) -> 
    let id = to_ast_id id in
    let key = id_to_string id in
    let typq,k_env = to_ast_typquant k_env typq in
    let fields = List.map (fun (atyp,id) -> (to_ast_typ k_env atyp),(to_ast_id id)) fields in (* Add check that all arms have unique names locally *)
    let td_rec = TD_aux(TD_record(id,to_ast_namescm name_scm_opt,typq,fields,false),(l,None)) in
    let typ = (match (typquant_to_quantkinds k_env typq) with
      | [ ] -> {k = K_Typ}
      | typs -> {k = K_Lam(typs,{k=K_Typ})}) in
    td_rec, (names,Envmap.insert k_env (key,typ), t_env)
  | Parse_ast.TD_variant(id,name_scm_opt,typq,arms,_) ->
    let id = to_ast_id id in
    let key = id_to_string id in
    let typq,k_env = to_ast_typquant k_env typq in
    let arms = List.map (fun (atyp,id) -> (to_ast_typ k_env atyp),(to_ast_id id)) arms in (* Add check that all arms have unique names *)
    let td_var = TD_aux(TD_variant(id,to_ast_namescm name_scm_opt,typq,arms,false),(l,None)) in
    let typ = (match (typquant_to_quantkinds k_env typq) with
      | [ ] -> {k = K_Typ}
      | typs -> {k = K_Lam(typs,{k=K_Typ})}) in
    td_var, (names,Envmap.insert k_env (key,typ), t_env)
  | Parse_ast.TD_enum(id,name_scm_opt,enums,_) -> 
    let id = to_ast_id id in
    let key = id_to_string id in
    let enums = List.map to_ast_id enums in
    let keys = List.map id_to_string enums in
    let td_enum = TD_aux(TD_enum(id,to_ast_namescm name_scm_opt,enums,false),(l,None)) in (* Add check that all enums have unique names *)
    let k_env = List.fold_right (fun k k_env -> Envmap.insert k_env (k,{k=K_Nat})) keys (Envmap.insert k_env (key,{k=K_Typ})) in
    td_enum, (names,k_env,t_env)
  | Parse_ast.TD_register(id,t1,t2,ranges) -> 
    let id = to_ast_id id in
    let key = id_to_string id in
    let n1 = to_ast_nexp k_env t1 in
    let n2 = to_ast_nexp k_env t2 in
    let ranges = List.map (fun (range,id) -> (to_ast_range range),to_ast_id id) ranges in
    TD_aux(TD_register(id,n1,n2,ranges),(l,None)), (names,Envmap.insert k_env (key, {k=K_Typ}),t_env))

let to_ast_rec (Parse_ast.Rec_aux(r,l): Parse_ast.rec_opt) : rec_opt =
  Rec_aux((match r with
  | Parse_ast.Rec_nonrec -> Rec_nonrec
  | Parse_ast.Rec_rec -> Rec_rec
  ),l)

let to_ast_tannot_opt (k_env : kind Envmap.t) (Parse_ast.Typ_annot_opt_aux(tp,l)) : tannot tannot_opt * kind Envmap.t =
  match tp with
  | Parse_ast.Typ_annot_opt_none -> raise (Reporting_basic.err_unreachable l "Parser generated typ annot opt none")
  | Parse_ast.Typ_annot_opt_some(tq,typ) ->
    let typq,k_env = to_ast_typquant k_env tq in
    Typ_annot_opt_aux(Typ_annot_opt_some(typq,to_ast_typ k_env typ),(l,None)),k_env

let to_ast_effects_opt (k_env : kind Envmap.t) (Parse_ast.Effects_opt_aux(e,l)) : tannot effects_opt =
  match e with
  | Parse_ast.Effects_opt_pure -> Effects_opt_aux(Effects_opt_pure,(l,None))
  | Parse_ast.Effects_opt_effects(typ) -> Effects_opt_aux(Effects_opt_effects(to_ast_effects k_env typ),(l,None))

let to_ast_funcl (names,k_env,t_env) (Parse_ast.FCL_aux(fcl,l) : Parse_ast.funcl) : (tannot funcl) =
  match fcl with
  | Parse_ast.FCL_Funcl(id,pat,exp) -> FCL_aux(FCL_Funcl(to_ast_id id, to_ast_pat k_env pat, to_ast_exp k_env exp),(l,None))

let to_ast_fundef  (names,k_env,t_env) (Parse_ast.FD_aux(fd,l):Parse_ast.fundef) : (tannot fundef) envs_out = 
  match fd with
  | Parse_ast.FD_function(rec_opt,tannot_opt,effects_opt,funcls) -> 
    let tannot_opt, k_env = to_ast_tannot_opt k_env tannot_opt in
    FD_aux(FD_function(to_ast_rec rec_opt, tannot_opt, to_ast_effects_opt k_env effects_opt, List.map (to_ast_funcl (names, k_env, t_env)) funcls), (l,None)), (names,k_env,t_env)
    
type def_progress =
    No_def
  | Def_place_holder of id * Parse_ast.l
  | Finished of tannot def

type partial_def = ((tannot def) * bool) ref * kind Envmap.t

let rec def_in_progress (id : id) (partial_defs : (id * partial_def) list) : partial_def option =
  match partial_defs with
  | [] -> None
  | (n,pd)::defs -> 
    (match n,id with
    | Id_aux(Id(n),_), Id_aux(Id(i),_) -> if (n = i) then Some(pd) else def_in_progress id defs
    | _,_ -> def_in_progress id defs)
      
let to_ast_def (names, k_env, t_env) partial_defs def : def_progress envs_out * (id * partial_def) list = 
  let envs = (names,k_env,t_env) in
  match def with
  | Parse_ast.DEF_aux(d,l) ->
    (match d with
    | Parse_ast.DEF_type(t_def) -> 
      let td,envs = to_ast_typedef envs t_def in
      ((Finished(DEF_aux(DEF_type(td),(l,None)))),envs),partial_defs
    | Parse_ast.DEF_fundef(f_def) -> 
      let fd,envs = to_ast_fundef envs f_def in
      ((Finished(DEF_aux(DEF_fundef(fd),(l,None)))),envs),partial_defs
    | Parse_ast.DEF_val(lbind) -> 
      let lb = to_ast_letbind k_env lbind in
      ((Finished(DEF_aux(DEF_val(lb),(l,None)))),envs),partial_defs
    | Parse_ast.DEF_spec(val_spec) -> 
      let vs,envs = to_ast_spec envs val_spec in
      ((Finished(DEF_aux(DEF_spec(vs),(l,None)))),envs),partial_defs
    | Parse_ast.DEF_default(typ_spec) -> 
      let default,envs = to_ast_default envs typ_spec in
      ((Finished(DEF_aux(DEF_default(default),(l,None)))),envs),partial_defs
    | Parse_ast.DEF_reg_dec(typ,id) ->
      let t = to_ast_typ k_env typ in
      let id = to_ast_id id in
      ((Finished(DEF_aux(DEF_reg_dec(t,id),(l,None)))),envs),partial_defs (*If tracking types here, update tenv and None*)
    | Parse_ast.DEF_scattered_function(rec_opt, tannot_opt, effects_opt, id) ->
      let rec_opt = to_ast_rec rec_opt in
      let tannot,k_env' = to_ast_tannot_opt k_env tannot_opt in
      let effects_opt = to_ast_effects_opt k_env' effects_opt in
      let id = to_ast_id id in
      (match (def_in_progress id partial_defs) with
      | None -> let partial_def = ref ((DEF_aux(DEF_fundef(FD_aux(FD_function(rec_opt,tannot,effects_opt,[]),(l,None))),(l,None))),false) in
                (No_def,envs),((id,(partial_def,k_env))::partial_defs)
      | Some(d,k) -> typ_error l "Scattered function definition header name already in use by scattered definition" (Some id) None)
    | Parse_ast.DEF_scattered_funcl(funcl) -> 
      (match funcl with
      | Parse_ast.FCL_aux(Parse_ast.FCL_Funcl(id,_,_),_) -> 
        let id = to_ast_id id in
        (match (def_in_progress id partial_defs) with
        | None -> typ_error l "Scattered function definition clause does not match any exisiting function definition headers" (Some id) None
        | Some(d,k) ->
          (match !d with
          | DEF_aux(DEF_fundef(FD_aux(FD_function(r,t,e,fcls),fl)),dl),false -> 
            let funcl = to_ast_funcl (names,k,t_env) funcl in (* Needs to be a merging of the new type vars added from the back typq and the types seen since then *)
            d:= (DEF_aux(DEF_fundef(FD_aux(FD_function(r,t,e,fcls@[funcl]),fl)),dl),false);
            (No_def,envs),partial_defs
          | _,true -> typ_error l "Scattered funciton definition clauses extends ended defintion" (Some id) None
          | _ -> typ_error l "Scattered function definition clause matches an existing scattered type definition header" (Some id) None)))
    | Parse_ast.DEF_scattered_variant(id,naming_scheme_opt,typquant) -> 
      let id = to_ast_id id in
      let name = to_ast_namescm naming_scheme_opt in
      let typq, k_env' = to_ast_typquant k_env typquant in
      (match (def_in_progress id partial_defs) with
      | None -> let partial_def = ref ((DEF_aux(DEF_type(TD_aux(TD_variant(id,name,typq,[],false),(l,None))),(l,None))),false) in
                (Def_place_holder(id,l),envs),(id,(partial_def,k_env'))::partial_defs
      | Some(d,k) -> typ_error l "Scattered type definition header name already in use by scattered definition" (Some id) None)
    | Parse_ast.DEF_scattered_unioncl(id,typ,arm_id) -> 
      let id = to_ast_id id in
      let arm_id = to_ast_id arm_id in
      (match (def_in_progress id partial_defs) with
      | None -> typ_error l "Scattered type definition clause does not match any existing type definition headers" (Some id) None
      | Some(d,k) ->
        (match !d with
        | (DEF_aux(DEF_type(TD_aux(TD_variant(id,name,typq,arms,false),tl)),dl), false) -> 
          let typ = to_ast_typ k typ in
          d:= (DEF_aux(DEF_type(TD_aux(TD_variant(id,name,typq,arms@[typ,arm_id],false),tl)),dl),false);
          (No_def,envs),partial_defs
        | _,true -> typ_error l "Scattered type definition clause extends ended definition" (Some id) None
        | _ -> typ_error l "Scattered type definition clause matches an existing scattered function definition header" (Some id) None))
    | Parse_ast.DEF_scattered_end(id) ->
      let id = to_ast_id id in
      (match (def_in_progress id partial_defs) with
      | None -> typ_error l "Scattered definition end does not match any open scattered definitions" (Some id) None
      | Some(d,k) ->
        (match !d with
        | (DEF_aux(DEF_type(_),_) as def),false ->
          d:= (def,true);
          (No_def,envs),partial_defs
        | (DEF_aux(DEF_fundef(_),_) as def),false ->
          d:= (def,true);
          ((Finished def), envs),partial_defs
        | _, true -> 
          typ_error l "Scattered definition ended multiple times" (Some id) None
        | _ -> raise (Reporting_basic.err_unreachable l "Something in partial_defs other than fundef and type")))
    )

let rec to_ast_defs_helper envs partial_defs = function
  | [] -> ([],envs,partial_defs)
  | d::ds  -> let ((d', envs), partial_defs) = to_ast_def envs partial_defs d in
              let (defs,envs,partial_defs) = to_ast_defs_helper envs partial_defs ds in
              (match d' with
              | Finished def -> (def::defs,envs, partial_defs)
              | No_def -> defs,envs,partial_defs
              | Def_place_holder(id,l) -> 
                (match (def_in_progress id partial_defs) with
                | None -> raise (Reporting_basic.err_unreachable l "Id stored in place holder not retrievable from partial defs")
                | Some(d,k) -> 
                  if (snd !d) 
                  then (fst !d) :: defs, envs, partial_defs
                  else typ_error l "Scattered type definition never ended" (Some id) None))                

let to_ast (default_names : Nameset.t) (kind_env : kind Envmap.t) (typ_env : t Envmap.t) (Parse_ast.Defs(defs)) =
  let defs,_,partial_defs = to_ast_defs_helper (default_names,kind_env,typ_env) [] defs in
  List.iter 
    (fun (id,(d,k)) -> 
      (match !d with
      | (DEF_aux(_,(l,_)),false) -> typ_error l "Scattered definition never ended" (Some id) None
      | (_, true) -> ()))
    partial_defs;
  (Defs defs)
