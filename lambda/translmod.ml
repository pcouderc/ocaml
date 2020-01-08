(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           *)
(*                                                                        *)
(*   Copyright 1996 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(* Translation from typed abstract syntax to lambda terms,
   for the module language *)

open Misc
open Asttypes
open Path
open Types
open Typedtree
open Lambda
open Translobj
open Translcore
open Translclass

type error =
  Circular_dependency of (Ident.t * Lambda.unsafe_info) list
| Conflicting_inline_attributes

exception Error of Location.t * error

let cons_opt x_opt xs =
  match x_opt with
  | None -> xs
  | Some x -> x :: xs

(* Keep track of the root path (from the root of the namespace to the
   currently compiled module expression).  Useful for naming extensions. *)

let global_path glob = Some(Pident glob)
let functor_path path param =
  match path with
    None -> None
  | Some p -> Some(Papply(p, Pident param))
let field_path path field =
  match path with
    None -> None
  | Some p -> Some(Pdot(p, Ident.name field))

(* Compile type extensions *)

let transl_type_extension env rootpath tyext body =
  List.fold_right
    (fun ext body ->
      let lam =
        transl_extension_constructor env (field_path rootpath ext.ext_id) ext
      in
      Llet(Strict, Pgenval, ext.ext_id, lam, body))
    tyext.tyext_constructors
    body

(* Compile a coercion *)

let rec apply_coercion loc strict restr arg =
  match restr with
    Tcoerce_none ->
      arg
  | Tcoerce_structure(pos_cc_list, id_pos_list) ->
      name_lambda strict arg (fun id ->
        let get_field pos =
          if pos < 0 then lambda_unit
          else Lprim(Pfield pos,[Lvar id], loc)
        in
        let lam =
          Lprim(Pmakeblock(0, Immutable, None),
                List.map (apply_coercion_field loc get_field) pos_cc_list,
                loc)
        in
        wrap_id_pos_list loc id_pos_list get_field lam)
  | Tcoerce_functor(cc_arg, cc_res) ->
      let param = Ident.create_local "funarg" in
      let carg = apply_coercion loc Alias cc_arg (Lvar param) in
      apply_coercion_result loc strict arg [param, Pgenval] [carg] cc_res
  | Tcoerce_primitive { pc_loc; pc_desc; pc_env; pc_type; } ->
      Translprim.transl_primitive pc_loc pc_desc pc_env pc_type None
  | Tcoerce_alias (env, path, cc) ->
      let lam = transl_module_path loc env path in
      name_lambda strict arg
        (fun _ -> apply_coercion loc Alias cc lam)

and apply_coercion_field loc get_field (pos, cc) =
  apply_coercion loc Alias cc (get_field pos)

and apply_coercion_result loc strict funct params args cc_res =
  match cc_res with
  | Tcoerce_functor(cc_arg, cc_res) ->
    let param = Ident.create_local "funarg" in
    let arg = apply_coercion loc Alias cc_arg (Lvar param) in
    apply_coercion_result loc strict funct
      ((param, Pgenval) :: params) (arg :: args) cc_res
  | _ ->
      name_lambda strict funct
        (fun id ->
           Lfunction
             {
               kind = Curried;
               params = List.rev params;
               return = Pgenval;
               attr = { default_function_attribute with
                        is_a_functor = true;
                        stub = true; };
               loc = loc;
               body = apply_coercion
                   loc Strict cc_res
                   (Lapply{ap_should_be_tailcall=false;
                           ap_loc=loc;
                           ap_func=Lvar id;
                           ap_args=List.rev args;
                           ap_inlined=Default_inline;
                           ap_specialised=Default_specialise})})

and wrap_id_pos_list loc id_pos_list get_field lam =
  let fv = free_variables lam in
  (*Format.eprintf "%a@." Printlambda.lambda lam;
  Ident.Set.iter (fun id -> Format.eprintf "%a " Ident.print id) fv;
  Format.eprintf "@.";*)
  let (lam,s) =
    List.fold_left (fun (lam, s) (id',pos,c) ->
      if Ident.Set.mem id' fv then
        let id'' = Ident.create_local (Ident.name id') in
        (Llet(Alias, Pgenval, id'',
             apply_coercion loc Alias c (get_field pos),lam),
         Ident.Map.add id' id'' s)
      else (lam, s))
      (lam, Ident.Map.empty) id_pos_list
  in
  if s == Ident.Map.empty then lam else Lambda.rename s lam


(* Compose two coercions
   apply_coercion c1 (apply_coercion c2 e) behaves like
   apply_coercion (compose_coercions c1 c2) e. *)

let rec compose_coercions c1 c2 =
  match (c1, c2) with
    (Tcoerce_none, c2) -> c2
  | (c1, Tcoerce_none) -> c1
  | (Tcoerce_structure (pc1, ids1), Tcoerce_structure (pc2, ids2)) ->
      let v2 = Array.of_list pc2 in
      let ids1 =
        List.map (fun (id,pos1,c1) ->
          let (pos2,c2) = v2.(pos1) in (id, pos2, compose_coercions c1 c2))
          ids1
      in
      Tcoerce_structure
        (List.map
           (fun pc ->
              match pc with
              | _, (Tcoerce_primitive _ | Tcoerce_alias _) ->
                (* These cases do not take an argument (the position is -1),
                   so they do not need adjusting. *)
                pc
              | (p1, c1) ->
                let (p2, c2) = v2.(p1) in
                (p2, compose_coercions c1 c2))
          pc1,
         ids1 @ ids2)
  | (Tcoerce_functor(arg1, res1), Tcoerce_functor(arg2, res2)) ->
      Tcoerce_functor(compose_coercions arg2 arg1,
                      compose_coercions res1 res2)
  | (c1, Tcoerce_alias (env, path, c2)) ->
      Tcoerce_alias (env, path, compose_coercions c1 c2)
  | (_, _) ->
      fatal_error "Translmod.compose_coercions"

(*
let apply_coercion a b c =
  Format.eprintf "@[<2>apply_coercion@ %a@]@." Includemod.print_coercion b;
  apply_coercion a b c

let compose_coercions c1 c2 =
  let c3 = compose_coercions c1 c2 in
  let open Includemod in
  Format.eprintf "@[<2>compose_coercions@ (%a)@ (%a) =@ %a@]@."
    print_coercion c1 print_coercion c2 print_coercion c3;
  c3
*)

(* Record the primitive declarations occurring in the module compiled *)

let primitive_declarations = ref ([] : Primitive.description list)
let record_primitive = function
  | {val_kind=Val_prim p;val_loc} ->
      Translprim.check_primitive_arity val_loc p;
      primitive_declarations := p :: !primitive_declarations
  | _ -> ()

(* Utilities for compiling "module rec" definitions *)

let mod_prim = Lambda.transl_prim "CamlinternalMod"

let undefined_location loc =
  let (fname, line, char) = Location.get_pos_info loc.Location.loc_start in
  Lconst(Const_block(0,
                     [Const_base(Const_string (fname, loc, None));
                      Const_base(Const_int line);
                      Const_base(Const_int char)]))

exception Initialization_failure of unsafe_info

let init_shape id modl : (Lambda.lambda * Lambda.shape, Lambda.unsafe_info) Result.t  =
  let rec init_shape_mod subid loc env mty =
    match Mtype.scrape env mty with
      Mty_ident _
    | Mty_alias _ ->
        raise (Initialization_failure
                (Info {reason=Unsafe_module_binding;info_loc=loc;subid}))
    | Mty_signature sg ->
        Module (init_shape_struct env sg)
        (* Const_block(0, [Const_block(0, init_shape_struct env sg)]) *)
    | Mty_functor _ ->
        (* can we do better? *)
        raise (Initialization_failure
                (Info {reason=Unsafe_functor;info_loc=loc;subid}))
  and init_shape_struct env sg =
    match sg with
      [] -> []
    | Sig_value(subid, {val_kind=Val_reg; val_type=ty; val_loc=loc},_) :: rem ->
        let init_v =
          match Ctype.expand_head env ty with
            {desc = Tarrow(_,_,_,_)} ->
              Function
              (* Const_pointer 0 (\* camlinternalMod.Function *\) *)
          | {desc = Tconstr(p, _, _)} when Path.same p Predef.path_lazy_t ->
              Lazy
              (* Const_pointer 1 (\* camlinternalMod.Lazy *\) *)
          | _ ->
              let not_a_function =
                Info {reason=Unsafe_non_function; info_loc=loc; subid }
              in
              raise (Initialization_failure not_a_function) in
        init_v :: init_shape_struct env rem
    | Sig_value(_, {val_kind=Val_prim _}, _) :: rem ->
        init_shape_struct env rem
    | Sig_value _ :: _rem ->
        assert false
    | Sig_type(id, tdecl, _, _) :: rem ->
        init_shape_struct (Env.add_type ~check:false id tdecl env) rem
    | Sig_typext (subid, {ext_loc=loc},_,_) :: _ ->
        raise (Initialization_failure (Info {reason=Unsafe_typext;info_loc=loc;subid}))
    | Sig_module(id, Mp_present, md, _, _) :: rem ->
        init_shape_mod id md.md_loc env md.md_type ::
        init_shape_struct (Env.add_module_declaration ~check:false
                             id Mp_present md env) rem
    | Sig_module(id, Mp_absent, md, _, _) :: rem ->
        init_shape_struct
          (Env.add_module_declaration ~check:false
                             id Mp_absent md env) rem
    | Sig_modtype(id, minfo, _) :: rem ->
        init_shape_struct (Env.add_modtype id minfo env) rem
    | Sig_class _ :: rem ->
        Class
        (* Const_pointer 2 (\* camlinternalMod.Class *\) *)
        :: init_shape_struct env rem
    | Sig_class_type _ :: rem ->
        init_shape_struct env rem
  in
  try
    Ok(undefined_location modl.mod_loc,
       init_shape_mod id modl.mod_loc modl.mod_env modl.mod_type)
  with Initialization_failure reason -> Result.Error(reason)

let shape_to_lambda shape =
  let rec transl = function
    | Function -> Const_pointer 0
    | Lazy -> Const_pointer 1
    | Class -> Const_pointer 2
    | Module l ->
        Const_block(0, [Const_block(0, List.map transl l)])
  in
  Lconst (transl shape)

(* Reorder bindings to honor dependencies.  *)

type recmod_kind =
    Recmod of Lambda.lambda
  | Recunit of Ident.t * Lambda.lambda list

type binding_status =
  | Undefined
  | Inprogress of int option (** parent node *)
  | Defined

type id_or_ignore_loc =
  | Id of Ident.t
  | Ignore_loc of Location.t

let extract_unsafe_cycle id status init cycle_start =
  let info i = match init.(i) with
    | Result.Error r ->
        begin match id.(i) with
        | Id id -> id, r
        | Ignore_loc _ ->
            assert false (* Can't refer to something without a name. *)
        end
    | Ok _ -> assert false in
  let rec collect stop l i = match status.(i) with
    | Inprogress None | Undefined | Defined -> assert false
    | Inprogress Some i when i = stop -> info i :: l
    | Inprogress Some i -> collect stop (info i::l) i in
  collect cycle_start [] cycle_start

let reorder_rec_bindings bindings =
  let id = Array.of_list (List.map (fun (id,_,_,_,_) -> id) bindings)
  and loc = Array.of_list (List.map (fun (_,loc,_,_,_) -> loc) bindings)
  and init = Array.of_list (List.map (fun (_,_,init,_,_) -> init) bindings)
  and rhs = Array.of_list (List.map (fun (_,_,_,rhs,_) -> rhs) bindings)
  and fv = Array.of_list (List.map (fun (_,_,_,_,fvs) -> fvs) bindings)in
  let num_bindings = Array.length id in
  let status = Array.make num_bindings Undefined in
  let res = ref [] in
  let is_unsafe i = match init.(i) with
    | Ok _ -> false
    | Result.Error _ -> true in
  let init_res i = match init.(i) with
    | Result.Error _ -> None
    | Ok(a,b) -> Some(a,b) in
  let rec emit_binding parent i =
    match status.(i) with
      Defined -> ()
    | Inprogress _ ->
        status.(i) <- Inprogress parent;
        let cycle = extract_unsafe_cycle id status init i in
        raise(Error(loc.(i), Circular_dependency cycle))
    | Undefined ->
        if is_unsafe i then begin
          status.(i) <- Inprogress parent;
          for j = 0 to num_bindings - 1 do
            match id.(j) with
            | Id id when Ident.Set.mem id fv.(i) -> emit_binding (Some i) j
            | _ -> ()
          done
        end;
        res := (id.(i), init_res i, rhs.(i)) :: !res;
        status.(i) <- Defined in
  for i = 0 to num_bindings - 1 do
    match status.(i) with
      Undefined -> emit_binding None i
    | Inprogress _ -> assert false
    | Defined -> ()
  done;
  List.rev !res

(* Generate lambda-code for a reordered list of bindings *)

let eval_rec_bindings bindings cont =
  let rec bind_inits = function
    [] ->
      bind_strict bindings
  | (Ignore_loc _, _, _) :: rem
  | (_, None, _) :: rem ->
      bind_inits rem
  | (Id id, Some(loc, shape), _rhs) :: rem ->
      let shape = shape_to_lambda shape in
      Llet(Strict, Pgenval, id,
           Lapply{ap_should_be_tailcall=false;
                  ap_loc=Location.none;
                  ap_func=mod_prim "init_mod";
                  ap_args=[loc; shape];
                  ap_inlined=Default_inline;
                  ap_specialised=Default_specialise},
           bind_inits rem)
  and bind_strict = function
    [] ->
      patch_forwards bindings
  | (Ignore_loc loc, None, Recmod rhs) :: rem ->
      Lsequence(Lprim(Pignore, [rhs], loc), bind_strict rem)
  | (Id id, None, Recmod rhs) :: rem ->
      Llet(Strict, Pgenval, id, rhs, bind_strict rem)
  | (_, None, Recunit _) :: _ ->
      bind_strict_recunits bindings
  | (_id, Some _, _rhs) :: rem ->
      bind_strict rem
  and bind_strict_recunits bindings =
    let to_bind =
      List.filter_map (function
          | Id id, None, Recunit (pers_id, recmods) ->
              let funct =
                Lprim(Pfield 0, [Lprim(Pgetglobal pers_id, [], Location.none)],
                      Location.none) in
              Some(id,
                   Lapply{ap_should_be_tailcall=false;
                          ap_loc=Location.none;
                          ap_func=funct;
                          ap_args=recmods;
                          ap_inlined=Default_inline;
                          ap_specialised=Default_specialise})
          | _ -> None) bindings in
    Lletrec(to_bind, patch_forwards bindings)
  and patch_forwards = function
    [] ->
      cont
  | (Ignore_loc _, _, _rhs) :: rem
  | (_, None, _rhs) :: rem ->
      patch_forwards rem
  | (Id id, Some(_loc, shape), Recmod rhs) :: rem ->
      let shape = shape_to_lambda shape in
      Lsequence(Lapply{ap_should_be_tailcall=false;
                       ap_loc=Location.none;
                       ap_func=mod_prim "update_mod";
                       ap_args=[shape; Lvar id; rhs];
                       ap_inlined=Default_inline;
                       ap_specialised=Default_specialise},
                patch_forwards rem)
  | (Id id, Some(_loc, shape), Recunit (pers_id, recmods)) :: rem ->
      let shape = shape_to_lambda shape in
      let funct =
        Lprim(Pfield 0, [Lprim(Pgetglobal pers_id, [], Location.none)],
              Location.none) in
      Lsequence(Lapply{ap_should_be_tailcall=false;
                       ap_loc=Location.none;
                       ap_func= funct;
                       ap_args=shape :: Lvar id :: recmods;
                       ap_inlined=Default_inline;
                       ap_specialised=Default_specialise},
                patch_forwards rem)
  in
    bind_inits bindings

let compile_recmodule_gen bindings cont =
  eval_rec_bindings
    (reorder_rec_bindings bindings)
    cont

let compile_recmodule compile_rhs bindings cont =
  compile_recmodule_gen
    (List.map
       (fun {mb_id=id; mb_expr=modl; mb_loc=loc; mb_name} ->
          let id_or_ignore_loc, shape =
               match id with
               | None -> Ignore_loc mb_name.loc, Result.Error Unnamed
               | Some id -> Id id, init_shape id modl
          in
          let rhs = compile_rhs id modl loc in
          let fvs = Lambda.free_variables rhs in
          (id_or_ignore_loc, modl.mod_loc, shape, Recmod rhs, fvs))
       bindings)
    cont

let compile_recunits components dependencies loc cont =
  let recmods = List.map (fun (_, id) -> id) components in
  let recdeps = List.map Env.recursive_pack_component_id dependencies in
  let recmods = recmods @ recdeps in
  compile_recmodule_gen
    (List.map
       (function
           PM_intf, _ -> assert false
         | PM_impl {member_recursive = None }, _ -> assert false
         | PM_impl {member_cu;
                    member_recursive = Some (shape, fvs);
                    member_recursive_dependencies}, id ->
             let pers_id =
               Ident.create_persistent
                 ~prefix:(Compilation_unit.for_pack_prefix member_cu)
                 (Compilation_unit.name member_cu)
             in
             let shape = match shape with
                 Ok s -> Ok (undefined_location loc, s)
               | Result.Error e -> Result.Error e in
             let recmods =
               List.map (fun cu ->
                   let fullpath = Compilation_unit.full_path_as_string cu in
                   let id =
                     List.find (fun id -> Ident.name id = fullpath) recmods in
                   Lvar id)
                 member_recursive_dependencies
             in
             (Id id, loc, shape, Recunit (pers_id, recmods), fvs))
       components)
    cont

(* Code to translate class entries in a structure *)

let transl_class_bindings cl_list =
  let ids = List.map (fun (ci, _) -> ci.ci_id_class) cl_list in
  (ids,
   List.map
     (fun ({ci_id_class=id; ci_expr=cl; ci_virt=vf}, meths) ->
       (id, transl_class ids id meths cl vf))
     cl_list)

(* Compile one or more functors, merging curried functors to produce
   multi-argument functors.  Any [@inline] attribute on a functor that is
   merged must be consistent with any other [@inline] attribute(s) on the
   functor(s) being merged with.  Such an attribute will be placed on the
   resulting merged functor. *)

let merge_inline_attributes attr1 attr2 loc =
  match Lambda.merge_inline_attributes attr1 attr2 with
  | Some attr -> attr
  | None -> raise (Error (loc, Conflicting_inline_attributes))

let merge_functors mexp coercion root_path =
  let rec merge mexp coercion path acc inline_attribute =
    let finished = acc, mexp, path, coercion, inline_attribute in
    match mexp.mod_desc with
    | Tmod_functor (param, body) ->
      let inline_attribute' =
        Translattribute.get_inline_attribute mexp.mod_attributes
      in
      let arg_coercion, res_coercion =
        match coercion with
        | Tcoerce_none -> Tcoerce_none, Tcoerce_none
        | Tcoerce_functor (arg_coercion, res_coercion) ->
          arg_coercion, res_coercion
        | _ -> fatal_error "Translmod.merge_functors: bad coercion"
      in
      let loc = mexp.mod_loc in
      let path, param =
        match param with
        | Unit -> None, Ident.create_local "*"
        | Named (None, _, _) ->
          let id = Ident.create_local "_" in
          functor_path path id, id
        | Named (Some id, _, _) -> functor_path path id, id
      in
      let inline_attribute =
        merge_inline_attributes inline_attribute inline_attribute' loc
      in
      merge body res_coercion path ((param, loc, arg_coercion) :: acc)
        inline_attribute
    | _ -> finished
  in
  merge mexp coercion root_path [] Default_inline

let rec compile_functor mexp coercion root_path loc =
  let functor_params_rev, body, body_path, res_coercion, inline_attribute =
    merge_functors mexp coercion root_path
  in
  assert (List.length functor_params_rev >= 1);  (* cf. [transl_module] *)
  let params, body =
    List.fold_left (fun (params, body) (param, loc, arg_coercion) ->
        let param' = Ident.rename param in
        let arg = apply_coercion loc Alias arg_coercion (Lvar param') in
        let params = (param', Pgenval) :: params in
        let body = Llet (Alias, Pgenval, param, arg, body) in
        params, body)
      ([], transl_module res_coercion body_path body)
      functor_params_rev
  in
  Lfunction {
    kind = Curried;
    params;
    return = Pgenval;
    attr = {
      inline = inline_attribute;
      specialise = Default_specialise;
      local = Default_local;
      is_a_functor = true;
      stub = false;
    };
    loc;
    body;
  }

(* Compile a module expression *)

and transl_module cc rootpath mexp =
  List.iter (Translattribute.check_attribute_on_module mexp)
    mexp.mod_attributes;
  let loc = mexp.mod_loc in
  match mexp.mod_desc with
  | Tmod_ident (path,_) ->
      apply_coercion loc Strict cc
        (transl_module_path loc mexp.mod_env path)
  | Tmod_structure str ->
      fst (transl_struct loc [] cc rootpath str)
  | Tmod_functor _ ->
      oo_wrap mexp.mod_env true (fun () ->
        compile_functor mexp cc rootpath loc) ()
  | Tmod_apply(funct, arg, ccarg) ->
      let inlined_attribute, funct =
        Translattribute.get_and_remove_inlined_attribute_on_module funct
      in
      oo_wrap mexp.mod_env true
        (apply_coercion loc Strict cc)
        (Lapply{ap_should_be_tailcall=false;
                ap_loc=loc;
                ap_func=transl_module Tcoerce_none None funct;
                ap_args=[transl_module ccarg None arg];
                ap_inlined=inlined_attribute;
                ap_specialised=Default_specialise})
  | Tmod_constraint(arg, _, _, ccarg) ->
      transl_module (compose_coercions cc ccarg) rootpath arg
  | Tmod_unpack(arg, _) ->
      apply_coercion loc Strict cc (Translcore.transl_exp arg)

and transl_struct loc fields cc rootpath str =
  transl_structure loc fields cc rootpath str.str_final_env str.str_items

(* The function  transl_structure is called by  the bytecode compiler.
   Some effort is made to compile in top to bottom order, in order to display
   warning by increasing locations. *)
and transl_structure loc fields cc rootpath final_env = function
    [] ->
      let body, size =
        match cc with
          Tcoerce_none ->
            Lprim(Pmakeblock(0, Immutable, None),
                  List.map (fun id -> Lvar id) (List.rev fields), loc),
              List.length fields
        | Tcoerce_structure(pos_cc_list, id_pos_list) ->
                (* Do not ignore id_pos_list ! *)
            (*Format.eprintf "%a@.@[" Includemod.print_coercion cc;
            List.iter (fun l -> Format.eprintf "%a@ " Ident.print l)
              fields;
            Format.eprintf "@]@.";*)
            let v = Array.of_list (List.rev fields) in
            let get_field pos =
              if pos < 0 then lambda_unit
              else Lvar v.(pos)
            in
            let ids = List.fold_right Ident.Set.add fields Ident.Set.empty in
            let lam =
              Lprim(Pmakeblock(0, Immutable, None),
                  List.map
                    (fun (pos, cc) ->
                      match cc with
                        Tcoerce_primitive p ->
                          Translprim.transl_primitive p.pc_loc
                            p.pc_desc p.pc_env p.pc_type None
                      | _ -> apply_coercion loc Strict cc (get_field pos))
                    pos_cc_list, loc)
            and id_pos_list =
              List.filter (fun (id,_,_) -> not (Ident.Set.mem id ids))
                id_pos_list
            in
            wrap_id_pos_list loc id_pos_list get_field lam,
              List.length pos_cc_list
        | _ ->
            fatal_error "Translmod.transl_structure"
      in
      (* This debugging event provides information regarding the structure
         items. It is ignored by the OCaml debugger but is used by
         Js_of_ocaml to preserve variable names. *)
      (if !Clflags.debug && not !Clflags.native_code then
         Levent(body,
                {lev_loc = loc;
                 lev_kind = Lev_pseudo;
                 lev_repr = None;
                 lev_env = final_env})
       else
         body),
      size
  | item :: rem ->
      match item.str_desc with
      | Tstr_eval (expr, _) ->
          let body, size =
            transl_structure loc fields cc rootpath final_env rem
          in
          Lsequence(transl_exp expr, body), size
      | Tstr_value(rec_flag, pat_expr_list) ->
          (* Translate bindings first *)
          let mk_lam_let = transl_let rec_flag pat_expr_list in
          let ext_fields =
            List.rev_append (let_bound_idents pat_expr_list) fields in
          (* Then, translate remainder of struct *)
          let body, size =
            transl_structure loc ext_fields cc rootpath final_env rem
          in
          mk_lam_let body, size
      | Tstr_primitive descr ->
          record_primitive descr.val_val;
          transl_structure loc fields cc rootpath final_env rem
      | Tstr_type _ ->
          transl_structure loc fields cc rootpath final_env rem
      | Tstr_typext(tyext) ->
          let ids = List.map (fun ext -> ext.ext_id) tyext.tyext_constructors in
          let body, size =
            transl_structure loc (List.rev_append ids fields)
              cc rootpath final_env rem
          in
          transl_type_extension item.str_env rootpath tyext body, size
      | Tstr_exception ext ->
          let id = ext.tyexn_constructor.ext_id in
          let path = field_path rootpath id in
          let body, size =
            transl_structure loc (id :: fields) cc rootpath final_env rem
          in
          Llet(Strict, Pgenval, id,
               transl_extension_constructor item.str_env
                                            path
                                            ext.tyexn_constructor, body),
          size
      | Tstr_module ({mb_presence=Mp_present} as mb) ->
          let id = mb.mb_id in
          (* Translate module first *)
          let module_body =
            transl_module Tcoerce_none (Option.bind id (field_path rootpath))
              mb.mb_expr
          in
          let module_body =
            Translattribute.add_inline_attribute module_body mb.mb_loc
                                                 mb.mb_attributes
          in
          (* Translate remainder second *)
          let body, size =
            transl_structure loc (cons_opt id fields) cc rootpath final_env rem
          in
          begin match id with
          | None ->
              Lsequence (Lprim(Pignore, [module_body], mb.mb_name.loc), body),
              size
          | Some id ->
              let module_body =
                Levent (module_body, {
                  lev_loc = mb.mb_loc;
                  lev_kind = Lev_module_definition id;
                  lev_repr = None;
                  lev_env = Env.empty;
                })
              in
              Llet(pure_module mb.mb_expr, Pgenval, id, module_body, body), size
          end
      | Tstr_module {mb_presence=Mp_absent} ->
          transl_structure loc fields cc rootpath final_env rem
      | Tstr_recmodule bindings ->
          let ext_fields =
            List.rev_append (List.filter_map (fun mb -> mb.mb_id) bindings)
              fields
          in
          let body, size =
            transl_structure loc ext_fields cc rootpath final_env rem
          in
          let lam =
            compile_recmodule (fun id modl loc ->
              match id with
              | None -> transl_module Tcoerce_none None modl
              | Some id ->
                  let module_body =
                    transl_module Tcoerce_none (field_path rootpath id) modl
                  in
                  Levent (module_body, {
                    lev_loc = loc;
                    lev_kind = Lev_module_definition id;
                    lev_repr = None;
                    lev_env = Env.empty;
                  })
            ) bindings body
          in
          lam, size
      | Tstr_class cl_list ->
          let (ids, class_bindings) = transl_class_bindings cl_list in
          let body, size =
            transl_structure loc (List.rev_append ids fields)
              cc rootpath final_env rem
          in
          Lletrec(class_bindings, body), size
      | Tstr_include incl ->
          let ids = bound_value_identifiers incl.incl_type in
          let modl = incl.incl_mod in
          let mid = Ident.create_local "include" in
          let rec rebind_idents pos newfields = function
              [] ->
                transl_structure loc newfields cc rootpath final_env rem
            | id :: ids ->
                let body, size =
                  rebind_idents (pos + 1) (id :: newfields) ids
                in
                Llet(Alias, Pgenval, id,
                     Lprim(Pfield pos, [Lvar mid], incl.incl_loc), body),
                size
          in
          let body, size = rebind_idents 0 fields ids in
          Llet(pure_module modl, Pgenval, mid,
               transl_module Tcoerce_none None modl, body),
          size

      | Tstr_open od ->
          let pure = pure_module od.open_expr in
          (* this optimization shouldn't be needed because Simplif would
             actually remove the [Llet] when it's not used.
             But since [scan_used_globals] runs before Simplif, we need to do
             it. *)
          begin match od.open_bound_items with
          | [] when pure = Alias ->
              transl_structure loc fields cc rootpath final_env rem
          | _ ->
              let ids = bound_value_identifiers od.open_bound_items in
              let mid = Ident.create_local "open" in
              let rec rebind_idents pos newfields = function
                  [] ->
                  transl_structure loc newfields cc rootpath final_env rem
                | id :: ids ->
                  let body, size =
                    rebind_idents (pos + 1) (id :: newfields) ids
                  in
                  Llet(Alias, Pgenval, id,
                      Lprim(Pfield pos, [Lvar mid], od.open_loc), body),
                  size
              in
              let body, size = rebind_idents 0 fields ids in
              Llet(pure, Pgenval, mid,
                    transl_module Tcoerce_none None od.open_expr, body), size
          end
      | Tstr_modtype _
      | Tstr_class_type _
      | Tstr_attribute _ ->
          transl_structure loc fields cc rootpath final_env rem

(* Update forward declaration in Translcore *)
let _ =
  Translcore.transl_module := transl_module

(* Introduce dependencies on modules referenced only by "external". *)

let scan_used_globals lam =
  let globals = ref Ident.Set.empty in
  let rec scan lam =
    Lambda.iter_head_constructor scan lam;
    match lam with
      Lprim ((Pgetglobal id | Psetglobal id), _, _) ->
        globals := Ident.Set.add id !globals
    | _ -> ()
  in
  scan lam; !globals

let required_globals ~flambda body =
  let globals = scan_used_globals body in
  let add_global id req =
    if not flambda && Ident.Set.mem id globals then
      req
    else
      Ident.Set.add id req
  in
  let required =
    List.fold_left
      (fun acc addr ->
         let unit = Env.address_head addr in
         add_global unit acc)
      (if flambda then globals else Ident.Set.empty)
      (Translprim.get_used_primitives ())
  in
  let required =
    List.fold_right (fun id req ->
        add_global id req)
      (Env.get_required_globals ()) required
  in
  Env.reset_required_globals ();
  Translprim.clear_used_primitives ();
  required

(* Compile an implementation *)

let transl_current_module_ident module_name =
  let prefix = Compilation_unit.Prefix.parse_for_pack !Clflags.for_package in
  Ident.create_persistent ~prefix module_name

let init_shape_implementation module_id str =
  let modl =
    { mod_desc = Tmod_structure str;
      mod_loc = Location.none;
      mod_type = Mty_signature str.str_type;
      mod_env = str.str_final_env;
      mod_attributes = [] }
  in
  match init_shape module_id modl with
    Ok (_, shape) -> Ok shape
  | Result.Error e -> Result.Error e

let init_shape_package components =
  let components_shape, fvs =
    List.fold_right (fun comp (acc_shape, pack_fvs) ->
        match acc_shape, comp with
          acc_shape, PM_intf ->
            acc_shape, pack_fvs
        | Result.Error e, _ ->
            Result.Error e, pack_fvs
        | Ok acc_shape, PM_impl { member_recursive } ->
            match member_recursive with
              None ->
                failwith "not compiled for recursive pack"
            | Some (Ok shape, fvs) ->
                Ok (shape :: acc_shape), Ident.Set.union pack_fvs fvs
            | Some (Result.Error e, fvs) ->
                Result.Error e, Ident.Set.union pack_fvs fvs)
      components
      (Ok [], Ident.Set.empty)
  in
  match components_shape with
    Ok l -> Ok (Module l), fvs
  | Result.Error e -> Result.Error e, fvs

let transl_recursive_implementation_strict rec_idents code =
  Lfunction {kind = Curried;
             params = rec_idents;
             return = Pgenval;
             body = code;
             attr = {
               inline = Default_inline;
               specialise = Default_specialise;
               local = Default_local;
               is_a_functor = true;
               stub = false;
             };
             loc = Location.in_file "translmod_rec_impl_strict"}, 1

let transl_recursive_implementation module_id shape rec_idents code =
  let code, size =
    match shape with
      Ok _ ->
        let component_id = Ident.create_local (Ident.name module_id) in
        let shape_id = Ident.create_local "shape" in
        let update_mod =
          Lapply{ap_should_be_tailcall=false;
                 ap_loc=Location.in_file "translmod_rec_impl-update_mod-apply";
                 ap_func=mod_prim "update_mod";
                 ap_args=[Lvar shape_id; Lvar component_id; code];
                 ap_inlined=Default_inline;
                 ap_specialised=Default_specialise}
        in
        Lfunction {kind = Curried;
                   params = (shape_id, Pgenval) :: (component_id, Pgenval)
                            :: rec_idents;
                   return = Pgenval;
                   body = update_mod;
                   attr = {
                     inline = Default_inline;
                     specialise = Default_specialise;
                     local = Default_local;
                     is_a_functor = true;
                     stub = false;
                   };
                   loc = Location.in_file "translmod_rec_impl-update_mod"}, 1
    | Result.Error _ ->
        (* In that case, the module is bound strictly, without update_mod *)
        transl_recursive_implementation_strict rec_idents code
  in
  code, size

let transl_implementation_aux module_id str cc =
  let code, size = transl_struct (Location.in_file "translmod_impl-struct") [] cc
      (global_path module_id) str
  in
  if Persistent_env.Current_unit.recursive_prefixes () <> [] then
    let shape = init_shape_implementation module_id str in
    let fvs = Lambda.free_variables code in
    let rec_idents =
      List.map (fun cu -> Env.recursive_pack_component_id cu, Pgenval)
        (Env.imports_from_recursive_pack ()) in
    let code, f_size =
      if Persistent_env.Current_unit.in_recursive_pack () then
        transl_recursive_implementation module_id shape rec_idents code
      else
        transl_recursive_implementation_strict rec_idents code in
    let funct_id = Ident.create_local ("functor_mod_impl") in
    Llet (Strict, Pgenval, funct_id, code,
          Lprim(Pmakeblock(0, Immutable, None), [Lvar funct_id],
                Location.in_file "translmod_impl-makebloc")),
    (f_size, Some (shape, fvs))
  else code, (size, None)

let transl_implementation_flambda module_name (str, cc) =
  reset_labels ();
  primitive_declarations := [];
  Translprim.clear_used_primitives ();
  let module_id = transl_current_module_ident module_name in
  let body, (size, recursive) =
    Translobj.transl_label_init
      (fun () -> transl_implementation_aux module_id str cc)
  in
  { module_ident = module_id;
    main_module_block_size = size;
    required_globals = required_globals ~flambda:true body;
    recursive;
    code = body }

let transl_implementation module_name (str, cc) =
  let implementation =
    transl_implementation_flambda module_name (str, cc)
  in
  let code =
    Lprim (Psetglobal implementation.module_ident, [implementation.code],
           Location.none)
  in
  { implementation with code }

(* Build the list of value identifiers defined by a toplevel structure
   (excluding primitive declarations). *)

let rec defined_idents = function
    [] -> []
  | item :: rem ->
    match item.str_desc with
    | Tstr_eval _ -> defined_idents rem
    | Tstr_value(_rec_flag, pat_expr_list) ->
      let_bound_idents pat_expr_list @ defined_idents rem
    | Tstr_primitive _ -> defined_idents rem
    | Tstr_type _ -> defined_idents rem
    | Tstr_typext tyext ->
      List.map (fun ext -> ext.ext_id) tyext.tyext_constructors
      @ defined_idents rem
    | Tstr_exception ext -> ext.tyexn_constructor.ext_id :: defined_idents rem
    | Tstr_module {mb_id = Some id; mb_presence=Mp_present} ->
      id :: defined_idents rem
    | Tstr_module ({mb_id = None}
                  |{mb_presence=Mp_absent}) -> defined_idents rem
    | Tstr_recmodule decls ->
      List.filter_map (fun mb -> mb.mb_id) decls @ defined_idents rem
    | Tstr_modtype _ -> defined_idents rem
    | Tstr_open od ->
      bound_value_identifiers od.open_bound_items @ defined_idents rem
    | Tstr_class cl_list ->
      List.map (fun (ci, _) -> ci.ci_id_class) cl_list @ defined_idents rem
    | Tstr_class_type _ -> defined_idents rem
    | Tstr_include incl ->
      bound_value_identifiers incl.incl_type @ defined_idents rem
    | Tstr_attribute _ -> defined_idents rem

(* second level idents (module M = struct ... let id = ... end),
   and all sub-levels idents *)
let rec more_idents = function
    [] -> []
  | item :: rem ->
    match item.str_desc with
    | Tstr_eval _ -> more_idents rem
    | Tstr_value _ -> more_idents rem
    | Tstr_primitive _ -> more_idents rem
    | Tstr_type _ -> more_idents rem
    | Tstr_typext _ -> more_idents rem
    | Tstr_exception _ -> more_idents rem
    | Tstr_recmodule _ -> more_idents rem
    | Tstr_modtype _ -> more_idents rem
    | Tstr_open od ->
        let rest = more_idents rem in
        begin match od.open_expr.mod_desc with
        | Tmod_structure str -> all_idents str.str_items @ rest
        | _ -> rest
        end
    | Tstr_class _ -> more_idents rem
    | Tstr_class_type _ -> more_idents rem
    | Tstr_include{incl_mod={mod_desc =
                             Tmod_constraint ({mod_desc = Tmod_structure str},
                                              _, _, _)}} ->
        all_idents str.str_items @ more_idents rem
    | Tstr_include _ -> more_idents rem
    | Tstr_module
        {mb_presence=Mp_present; mb_expr={mod_desc = Tmod_structure str}}
    | Tstr_module
        {mb_presence=Mp_present;
         mb_expr={mod_desc=
           Tmod_constraint ({mod_desc = Tmod_structure str}, _, _, _)}} ->
        all_idents str.str_items @ more_idents rem
    | Tstr_module _ -> more_idents rem
    | Tstr_attribute _ -> more_idents rem

and all_idents = function
    [] -> []
  | item :: rem ->
    match item.str_desc with
    | Tstr_eval _ -> all_idents rem
    | Tstr_value(_rec_flag, pat_expr_list) ->
      let_bound_idents pat_expr_list @ all_idents rem
    | Tstr_primitive _ -> all_idents rem
    | Tstr_type _ -> all_idents rem
    | Tstr_typext tyext ->
      List.map (fun ext -> ext.ext_id) tyext.tyext_constructors
      @ all_idents rem
    | Tstr_exception ext -> ext.tyexn_constructor.ext_id :: all_idents rem
    | Tstr_recmodule decls ->
      List.filter_map (fun mb -> mb.mb_id) decls @ all_idents rem
    | Tstr_modtype _ -> all_idents rem
    | Tstr_open od ->
        let rest = all_idents rem in
        begin match od.open_expr.mod_desc with
        | Tmod_structure str ->
          bound_value_identifiers od.open_bound_items
          @ all_idents str.str_items
          @ rest
        | _ -> bound_value_identifiers od.open_bound_items @ rest
        end
    | Tstr_class cl_list ->
      List.map (fun (ci, _) -> ci.ci_id_class) cl_list @ all_idents rem
    | Tstr_class_type _ -> all_idents rem

    | Tstr_include{incl_type; incl_mod={mod_desc =
                             Tmod_constraint ({mod_desc = Tmod_structure str},
                                              _, _, _)}} ->
        bound_value_identifiers incl_type
        @ all_idents str.str_items
        @ all_idents rem
    | Tstr_include incl ->
      bound_value_identifiers incl.incl_type @ all_idents rem

    | Tstr_module
        { mb_id = Some id;
          mb_presence=Mp_present;
          mb_expr={mod_desc = Tmod_structure str} }
    | Tstr_module
        { mb_id = Some id;
          mb_presence = Mp_present;
          mb_expr =
            {mod_desc =
               Tmod_constraint ({mod_desc = Tmod_structure str}, _, _, _)}} ->
        id :: all_idents str.str_items @ all_idents rem
    | Tstr_module {mb_id = Some id;mb_presence=Mp_present} ->
        id :: all_idents rem
    | Tstr_module ({mb_id = None} | {mb_presence=Mp_absent}) -> all_idents rem
    | Tstr_attribute _ -> all_idents rem


(* A variant of transl_structure used to compile toplevel structure definitions
   for the native-code compiler. Store the defined values in the fields
   of the global as soon as they are defined, in order to reduce register
   pressure.  Also rewrites the defining expressions so that they
   refer to earlier fields of the structure through the fields of
   the global, not by their names.
   "map" is a table from defined idents to (pos in global block, coercion).
   "prim" is a list of (pos in global block, primitive declaration). *)

let transl_store_subst = ref Ident.Map.empty
  (** In the native toplevel, this reference is threaded through successive
      calls of transl_store_structure *)

let nat_toplevel_name id =
  try match Ident.Map.find id !transl_store_subst with
    | Lprim(Pfield pos, [Lprim(Pgetglobal glob, [], _)], _) -> (glob,pos)
    | _ -> raise Not_found
  with Not_found ->
    fatal_error("Translmod.nat_toplevel_name: " ^ Ident.unique_name id)

let field_of_str loc str =
  let ids = Array.of_list (defined_idents str.str_items) in
  fun (pos, cc) ->
    match cc with
    | Tcoerce_primitive { pc_loc; pc_desc; pc_env; pc_type; } ->
        Translprim.transl_primitive pc_loc pc_desc pc_env pc_type None
    | Tcoerce_alias (env, path, cc) ->
        let lam = transl_module_path loc env path in
        apply_coercion loc Alias cc lam
    | _ -> apply_coercion loc Strict cc (Lvar ids.(pos))


let transl_store_structure glob map prims aliases str =
  let no_env_update _ _ env = env in
  let rec transl_store rootpath subst cont = function
    [] ->
      transl_store_subst := subst;
      Lambda.subst no_env_update subst cont
    | item :: rem ->
        match item.str_desc with
        | Tstr_eval (expr, _attrs) ->
            Lsequence(Lambda.subst no_env_update subst (transl_exp expr),
                      transl_store rootpath subst cont rem)
        | Tstr_value(rec_flag, pat_expr_list) ->
            let ids = let_bound_idents pat_expr_list in
            let lam =
              transl_let rec_flag pat_expr_list
                (store_idents Location.none ids)
            in
            Lsequence(Lambda.subst no_env_update subst lam,
                      transl_store rootpath
                        (add_idents false ids subst) cont rem)
        | Tstr_primitive descr ->
            record_primitive descr.val_val;
            transl_store rootpath subst cont rem
        | Tstr_type _ ->
            transl_store rootpath subst cont rem
        | Tstr_typext(tyext) ->
            let ids =
              List.map (fun ext -> ext.ext_id) tyext.tyext_constructors
            in
            let lam =
              transl_type_extension item.str_env rootpath tyext
                                    (store_idents Location.none ids)
            in
            Lsequence(Lambda.subst no_env_update subst lam,
                      transl_store rootpath
                        (add_idents false ids subst) cont rem)
        | Tstr_exception ext ->
            let id = ext.tyexn_constructor.ext_id in
            let path = field_path rootpath id in
            let lam =
              transl_extension_constructor item.str_env
                                           path
                                           ext.tyexn_constructor
            in
            Lsequence(Llet(Strict, Pgenval, id,
                           Lambda.subst no_env_update subst lam,
                           store_ident ext.tyexn_constructor.ext_loc id),
                      transl_store rootpath
                        (add_ident false id subst) cont rem)
        | Tstr_module
            {mb_id=None; mb_name; mb_presence=Mp_present; mb_expr=modl;
             mb_loc=loc; mb_attributes} ->
            let lam =
              Translattribute.add_inline_attribute
                (transl_module Tcoerce_none None modl)
                loc mb_attributes
            in
            Lsequence(Lprim(Pignore, [lam], mb_name.loc),
                      transl_store rootpath subst cont rem)
        | Tstr_module{mb_id=Some id;mb_loc=loc;mb_presence=Mp_present;
                      mb_expr={mod_desc = Tmod_structure str} as mexp;
                      mb_attributes} ->
            List.iter (Translattribute.check_attribute_on_module mexp)
              mb_attributes;
            let lam =
              transl_store (field_path rootpath id) subst
                lambda_unit str.str_items
            in
            (* Careful: see next case *)
            let subst = !transl_store_subst in
            Lsequence(lam,
                      Llet(Strict, Pgenval, id,
                           Lambda.subst no_env_update subst
                             (Lprim(Pmakeblock(0, Immutable, None),
                                    List.map (fun id -> Lvar id)
                                      (defined_idents str.str_items), loc)),
                           Lsequence(store_ident loc id,
                                     transl_store rootpath
                                                  (add_ident true id subst)
                                                  cont rem)))
        | Tstr_module{
            mb_id=Some id;mb_loc=loc;mb_presence=Mp_present;
            mb_expr= {
              mod_desc = Tmod_constraint (
                  {mod_desc = Tmod_structure str} as mexp, _, _,
                  (Tcoerce_structure (map, _) as _cc))};
            mb_attributes
          } ->
            (*    Format.printf "coerc id %s: %a@." (Ident.unique_name id)
                                Includemod.print_coercion cc; *)
            List.iter (Translattribute.check_attribute_on_module mexp)
              mb_attributes;
            let lam =
              transl_store (field_path rootpath id) subst
                lambda_unit str.str_items
            in
            (* Careful: see next case *)
            let subst = !transl_store_subst in
            let field = field_of_str loc str in
            Lsequence(lam,
                      Llet(Strict, Pgenval, id,
                           Lambda.subst no_env_update subst
                             (Lprim(Pmakeblock(0, Immutable, None),
                                    List.map field map, loc)),
                           Lsequence(store_ident loc id,
                                     transl_store rootpath
                                                  (add_ident true id subst)
                                                  cont rem)))
        | Tstr_module
            {mb_id=Some id; mb_presence=Mp_present; mb_expr=modl;
             mb_loc=loc; mb_attributes} ->
            let lam =
              Translattribute.add_inline_attribute
                (transl_module Tcoerce_none (field_path rootpath id) modl)
                loc mb_attributes
            in
            (* Careful: the module value stored in the global may be different
               from the local module value, in case a coercion is applied.
               If so, keep using the local module value (id) in the remainder of
               the compilation unit (add_ident true returns subst unchanged).
               If not, we can use the value from the global
               (add_ident true adds id -> Pgetglobal... to subst). *)
            Llet(Strict, Pgenval, id, Lambda.subst no_env_update subst lam,
                 Lsequence(store_ident loc id,
                           transl_store rootpath (add_ident true id subst)
                             cont rem))
        | Tstr_module {mb_presence=Mp_absent} ->
            transl_store rootpath subst cont rem
        | Tstr_recmodule bindings ->
            let ids = List.filter_map (fun mb -> mb.mb_id) bindings in
            compile_recmodule
              (fun id modl _loc ->
                 Lambda.subst no_env_update subst
                   (transl_module Tcoerce_none
                      (Option.bind id (field_path rootpath)) modl))
              bindings
              (Lsequence(store_idents Location.none ids,
                         transl_store rootpath (add_idents true ids subst)
                           cont rem))
        | Tstr_class cl_list ->
            let (ids, class_bindings) = transl_class_bindings cl_list in
            let lam =
              Lletrec(class_bindings, store_idents Location.none ids)
            in
            Lsequence(Lambda.subst no_env_update subst lam,
                      transl_store rootpath (add_idents false ids subst)
                        cont rem)

        | Tstr_include{
            incl_loc=loc;
            incl_mod= {
              mod_desc = Tmod_constraint (
                  ({mod_desc = Tmod_structure str} as mexp), _, _,
                  (Tcoerce_structure (map, _)))};
            incl_attributes;
            incl_type;
          } ->
            List.iter (Translattribute.check_attribute_on_module mexp)
              incl_attributes;
            (* Shouldn't we use mod_attributes instead of incl_attributes?
               Same question for the Tstr_module cases above, btw. *)
            let lam =
              transl_store None subst lambda_unit str.str_items
                (* It is tempting to pass rootpath instead of None
                   in order to give a more precise name to exceptions
                   in the included structured, but this would introduce
                   a difference of behavior compared to bytecode. *)
            in
            let subst = !transl_store_subst in
            let field = field_of_str loc str in
            let ids0 = bound_value_identifiers incl_type in
            let rec loop ids args =
              match ids, args with
              | [], [] ->
                  transl_store rootpath (add_idents true ids0 subst)
                    cont rem
              | id :: ids, arg :: args ->
                  Llet(Alias, Pgenval, id,
                       Lambda.subst no_env_update subst (field arg),
                       Lsequence(store_ident loc id,
                                 loop ids args))
              | _ -> assert false
            in
            Lsequence(lam, loop ids0 map)


        | Tstr_include incl ->
            let ids = bound_value_identifiers incl.incl_type in
            let modl = incl.incl_mod in
            let mid = Ident.create_local "include" in
            let loc = incl.incl_loc in
            let rec store_idents pos = function
              | [] ->
                transl_store rootpath (add_idents true ids subst) cont rem
              | id :: idl ->
                  Llet(Alias, Pgenval, id, Lprim(Pfield pos, [Lvar mid], loc),
                       Lsequence(store_ident loc id,
                                 store_idents (pos + 1) idl))
            in
            Llet(Strict, Pgenval, mid,
                 Lambda.subst no_env_update subst
                   (transl_module Tcoerce_none None modl),
                 store_idents 0 ids)
        | Tstr_open od ->
            begin match od.open_expr.mod_desc with
            | Tmod_structure str ->
                let lam =
                  transl_store rootpath subst lambda_unit str.str_items
                in
                let ids = Array.of_list (defined_idents str.str_items) in
                let ids0 = bound_value_identifiers od.open_bound_items in
                let subst = !transl_store_subst in
                let rec store_idents pos = function
                  | [] ->
                    transl_store rootpath (add_idents true ids0 subst) cont rem
                  | id :: idl ->
                      Llet(Alias, Pgenval, id, Lvar ids.(pos),
                           Lsequence(store_ident od.open_loc id,
                                     store_idents (pos + 1) idl))
                in
                Lsequence(lam, Lambda.subst no_env_update subst
                                 (store_idents 0 ids0))
            | _ ->
                let pure = pure_module od.open_expr in
                (* this optimization shouldn't be needed because Simplif would
                   actually remove the [Llet] when it's not used.
                   But since [scan_used_globals] runs before Simplif, we need to
                   do it. *)
                match od.open_bound_items with
                | [] when pure = Alias -> transl_store rootpath subst cont rem
                | _ ->
                    let ids = bound_value_identifiers od.open_bound_items in
                    let mid = Ident.create_local "open" in
                    let loc = od.open_loc in
                    let rec store_idents pos = function
                        [] ->
                          transl_store rootpath (add_idents true ids subst) cont
                            rem
                      | id :: idl ->
                          Llet(Alias, Pgenval, id, Lprim(Pfield pos, [Lvar mid],
                                                         loc),
                               Lsequence(store_ident loc id,
                                         store_idents (pos + 1) idl))
                    in
                    Llet(pure, Pgenval, mid,
                         Lambda.subst no_env_update subst
                           (transl_module Tcoerce_none None od.open_expr),
                         store_idents 0 ids)
          end
        | Tstr_modtype _
        | Tstr_class_type _
        | Tstr_attribute _ ->
            transl_store rootpath subst cont rem

  and store_ident loc id =
    try
      let (pos, cc) = Ident.find_same id map in
      let init_val = apply_coercion loc Alias cc (Lvar id) in
      Lprim(Psetfield(pos, Pointer, Root_initialization),
            [Lprim(Pgetglobal glob, [], loc); init_val],
            loc)
    with Not_found ->
      fatal_error("Translmod.store_ident: " ^ Ident.unique_name id)

  and store_idents loc idlist =
    make_sequence (store_ident loc) idlist

  and add_ident may_coerce id subst =
    try
      let (pos, cc) = Ident.find_same id map in
      match cc with
        Tcoerce_none ->
          Ident.Map.add id
            (Lprim(Pfield pos,
                   [Lprim(Pgetglobal glob, [], Location.none)],
                   Location.none))
            subst
      | _ ->
          if may_coerce then subst else assert false
    with Not_found ->
      assert false

  and add_idents may_coerce idlist subst =
    List.fold_right (add_ident may_coerce) idlist subst

  and store_primitive (pos, prim) cont =
    Lsequence(Lprim(Psetfield(pos, Pointer, Root_initialization),
                    [Lprim(Pgetglobal glob, [], Location.none);
                     Translprim.transl_primitive Location.none
                       prim.pc_desc prim.pc_env prim.pc_type None],
                    Location.none),
              cont)

  and store_alias (pos, env, path, cc) =
    let path_lam = transl_module_path Location.none env path in
    let init_val = apply_coercion Location.none Strict cc path_lam in
    Lprim(Psetfield(pos, Pointer, Root_initialization),
          [Lprim(Pgetglobal glob, [], Location.none);
           init_val],
          Location.none)
  in
  let aliases = make_sequence store_alias aliases in
  List.fold_right store_primitive prims
    (transl_store (global_path glob) !transl_store_subst aliases str)

(* Transform a coercion and the list of value identifiers defined by
   a toplevel structure into a table [id -> (pos, coercion)],
   with [pos] being the position in the global block where the value of
   [id] must be stored, and [coercion] the coercion to be applied to it.
   A given identifier may appear several times
   in the coercion (if it occurs several times in the signature); remember
   to assign it the position of its last occurrence.
   Identifiers that are not exported are assigned positions at the
   end of the block (beyond the positions of all exported idents).
   Also compute the total size of the global block,
   and the list of all primitives exported as values. *)

let build_ident_map restr idlist more_ids =
  let rec natural_map pos map prims aliases = function
    | [] ->
        (map, prims, aliases, pos)
    | id :: rem ->
        natural_map (pos+1)
          (Ident.add id (pos, Tcoerce_none) map) prims aliases rem
  in
  let (map, prims, aliases, pos) =
    match restr with
    | Tcoerce_none ->
        natural_map 0 Ident.empty [] [] idlist
    | Tcoerce_structure (pos_cc_list, _id_pos_list) ->
        (* ignore _id_pos_list as the ids are already bound *)
        let idarray = Array.of_list idlist in
        let rec export_map pos map prims aliases undef = function
          | [] ->
              natural_map pos map prims aliases undef
          | (_source_pos, Tcoerce_primitive p) :: rem ->
              export_map (pos + 1) map
                ((pos, p) :: prims) aliases undef rem
          | (_source_pos, Tcoerce_alias(env, path, cc)) :: rem ->
              export_map (pos + 1) map prims
                ((pos, env, path, cc) :: aliases) undef rem
          | (source_pos, cc) :: rem ->
              let id = idarray.(source_pos) in
              export_map (pos + 1) (Ident.add id (pos, cc) map)
                prims aliases (list_remove id undef) rem
        in
        export_map 0 Ident.empty [] [] idlist pos_cc_list
    | _ ->
        fatal_error "Translmod.build_ident_map"
  in
  natural_map pos map prims aliases more_ids

(* Compile an implementation using transl_store_structure
   (for the native-code compiler). *)

let transl_store_gen_init current_unit =
  reset_labels ();
  primitive_declarations := [];
  Translprim.clear_used_primitives ();
  transl_current_module_ident current_unit

let transl_store_structure_gen module_id ({str_items = str}, restr) topl =
  let (map, prims, aliases, size) =
    build_ident_map restr (defined_idents str) (more_idents str) in
  let f = function
    | [ { str_desc = Tstr_eval (expr, _attrs) } ] when topl ->
        assert (size = 0);
        Lambda.subst (fun _ _ env -> env) !transl_store_subst (transl_exp expr)
    | str -> transl_store_structure module_id map prims aliases str
  in
  transl_store_label_init module_id size f str
  (*size, transl_label_init (transl_store_structure module_id map prims str)*)

let transl_store_recursive_implementation module_id ((impl, restr)) =
  let code, _ =
    transl_struct Location.none [] restr (global_path module_id) impl in
  let shape = init_shape_implementation module_id impl in
  let fvs = Lambda.free_variables code in
  let rec_idents =
    List.map (fun cu -> Env.recursive_pack_component_id cu, Pgenval)
      (Env.imports_from_recursive_pack ()) in
  let funct, size =
    if Persistent_env.Current_unit.in_recursive_pack () then
      transl_recursive_implementation module_id shape rec_idents code
    else
      transl_recursive_implementation_strict rec_idents code
  in
  let body_id = Ident.create_local "*body*" in
  (size,
   Llet (Strict, Pgenval, body_id, funct,
         Lsequence (Lprim(Psetfield(0, Pointer, Root_initialization),
                          [Lprim(Pgetglobal module_id, [], Location.none);
                           Lvar body_id],
                          Location.none),
                    lambda_unit))),
  Some (shape, fvs)

let transl_store_phrases module_name str =
  let module_id = transl_store_gen_init module_name in
  transl_store_structure_gen module_id (str, Tcoerce_none) true

let transl_store_gen module_id (impl, restr) topl =
  if !Clflags.recursive_interfaces || !Clflags.recursive_packages <> [] then
    transl_store_recursive_implementation module_id (impl, restr)
  else transl_store_structure_gen module_id (impl, restr) topl, None

let transl_store_implementation module_name (impl, restr) =
  let s = !transl_store_subst in
  transl_store_subst := Ident.Map.empty;
  let module_id = transl_store_gen_init module_name in
  let (i, code), recursive = transl_store_gen module_id (impl, restr) false
  in
  transl_store_subst := s;
  { Lambda.main_module_block_size = i;
    code;
    (* module_ident is not used by closure, but this allow to share
       the type with the flambda version *)
    module_ident = Ident.create_persistent module_name;
    required_globals = required_globals ~flambda:true code;
    recursive }

(* Compile a toplevel phrase *)

let toploop_ident = Ident.create_persistent "Toploop"
let toploop_getvalue_pos = 0 (* position of getvalue in module Toploop *)
let toploop_setvalue_pos = 1 (* position of setvalue in module Toploop *)

let aliased_idents = ref Ident.empty

let set_toplevel_unique_name id =
  aliased_idents :=
    Ident.add id (Ident.unique_toplevel_name id) !aliased_idents

let toplevel_name id =
  try Ident.find_same id !aliased_idents
  with Not_found -> Ident.name id

let toploop_getvalue id =
  Lapply{ap_should_be_tailcall=false;
         ap_loc=Location.none;
         ap_func=Lprim(Pfield toploop_getvalue_pos,
                       [Lprim(Pgetglobal toploop_ident, [], Location.none)],
                       Location.none);
         ap_args=[Lconst(Const_base(
             Const_string (toplevel_name id, Location.none,None)))];
         ap_inlined=Default_inline;
         ap_specialised=Default_specialise}

let toploop_setvalue id lam =
  Lapply{ap_should_be_tailcall=false;
         ap_loc=Location.none;
         ap_func=Lprim(Pfield toploop_setvalue_pos,
                       [Lprim(Pgetglobal toploop_ident, [], Location.none)],
                       Location.none);
         ap_args=[Lconst(Const_base(
             Const_string (toplevel_name id, Location.none, None)));
                  lam];
         ap_inlined=Default_inline;
         ap_specialised=Default_specialise}

let toploop_setvalue_id id = toploop_setvalue id (Lvar id)

let close_toplevel_term (lam, ()) =
  Ident.Set.fold (fun id l -> Llet(Strict, Pgenval, id,
                                  toploop_getvalue id, l))
                (free_variables lam) lam

let transl_toplevel_item item =
  match item.str_desc with
    Tstr_eval (expr, _)
  | Tstr_value(Nonrecursive,
               [{vb_pat = {pat_desc=Tpat_any};vb_expr = expr}]) ->
      (* special compilation for toplevel "let _ = expr", so
         that Toploop can display the result of the expression.
         Otherwise, the normal compilation would result
         in a Lsequence returning unit. *)
      transl_exp expr
  | Tstr_value(rec_flag, pat_expr_list) ->
      let idents = let_bound_idents pat_expr_list in
      transl_let rec_flag pat_expr_list
        (make_sequence toploop_setvalue_id idents)
  | Tstr_typext(tyext) ->
      let idents =
        List.map (fun ext -> ext.ext_id) tyext.tyext_constructors
      in
      (* we need to use unique name in case of multiple
         definitions of the same extension constructor in the toplevel *)
      List.iter set_toplevel_unique_name idents;
        transl_type_extension item.str_env None tyext
          (make_sequence toploop_setvalue_id idents)
  | Tstr_exception ext ->
      set_toplevel_unique_name ext.tyexn_constructor.ext_id;
      toploop_setvalue ext.tyexn_constructor.ext_id
        (transl_extension_constructor item.str_env None ext.tyexn_constructor)
  | Tstr_module {mb_id=None; mb_presence=Mp_present; mb_expr=modl} ->
      transl_module Tcoerce_none None modl
  | Tstr_module {mb_id=Some id; mb_presence=Mp_present; mb_expr=modl} ->
      (* we need to use the unique name for the module because of issues
         with "open" (PR#8133) *)
      set_toplevel_unique_name id;
      let lam = transl_module Tcoerce_none (Some(Pident id)) modl in
      toploop_setvalue id lam
  | Tstr_recmodule bindings ->
      let idents = List.filter_map (fun mb -> mb.mb_id) bindings in
      compile_recmodule
        (fun id modl _loc ->
           transl_module Tcoerce_none (Option.map (fun i -> Pident i) id) modl)
        bindings
        (make_sequence toploop_setvalue_id idents)
  | Tstr_class cl_list ->
      (* we need to use unique names for the classes because there might
         be a value named identically *)
      let (ids, class_bindings) = transl_class_bindings cl_list in
      List.iter set_toplevel_unique_name ids;
      Lletrec(class_bindings, make_sequence toploop_setvalue_id ids)
  | Tstr_include incl ->
      let ids = bound_value_identifiers incl.incl_type in
      let modl = incl.incl_mod in
      let mid = Ident.create_local "include" in
      let rec set_idents pos = function
        [] ->
          lambda_unit
      | id :: ids ->
          Lsequence(toploop_setvalue id
                      (Lprim(Pfield pos, [Lvar mid], Location.none)),
                    set_idents (pos + 1) ids) in
      Llet(Strict, Pgenval, mid,
           transl_module Tcoerce_none None modl, set_idents 0 ids)
  | Tstr_primitive descr ->
      record_primitive descr.val_val;
      lambda_unit
  | Tstr_open od ->
      let pure = pure_module od.open_expr in
      (* this optimization shouldn't be needed because Simplif would
          actually remove the [Llet] when it's not used.
          But since [scan_used_globals] runs before Simplif, we need to do
          it. *)
      begin match od.open_bound_items with
      | [] when pure = Alias -> lambda_unit
      | _ ->
          let ids = bound_value_identifiers od.open_bound_items in
          let mid = Ident.create_local "open" in
          let rec set_idents pos = function
              [] ->
                lambda_unit
            | id :: ids ->
                Lsequence(toploop_setvalue id
                            (Lprim(Pfield pos, [Lvar mid], Location.none)),
                          set_idents (pos + 1) ids)
          in
          Llet(pure, Pgenval, mid,
               transl_module Tcoerce_none None od.open_expr, set_idents 0 ids)
      end
  | Tstr_modtype _
  | Tstr_module {mb_presence=Mp_absent}
  | Tstr_type _
  | Tstr_class_type _
  | Tstr_attribute _ ->
      lambda_unit

let transl_toplevel_item_and_close itm =
  close_toplevel_term
    (transl_label_init (fun () -> transl_toplevel_item itm, ()))

let transl_toplevel_definition str =
  reset_labels ();
  Translprim.clear_used_primitives ();
  make_sequence transl_toplevel_item_and_close str.str_items

(* Compile the initialization code for a packed library *)

let get_component = function
    PM_intf -> Lconst const_unit
  | PM_impl { member_cu; _ } ->
      let pers_id =
        Ident.create_persistent
          ~prefix:(Compilation_unit.for_pack_prefix member_cu)
          (Compilation_unit.name member_cu)
      in
      Lprim(Pgetglobal pers_id, [], Location.none)

let transl_recursive_subpackage_gen
    module_id components recdeps bind_components =
  let ids =
    List.fold_left (fun acc (_, cu) -> cu :: acc)
      (List.map Env.recursive_pack_component_id recdeps)
      components
  in
  let persistent_id cu =
    Ident.create_persistent
      ~prefix:(Compilation_unit.for_pack_prefix cu)
      (Compilation_unit.name cu)
  in
  let generate_args deps =
    List.map (fun cu ->
        try
          let id =
            List.find (fun id ->
                Ident.name id = Compilation_unit.full_path_as_string cu) ids
          in
          Lvar id
        with Not_found ->
          failwith (Format.asprintf "Not_found %a"
                      Compilation_unit.print cu))
      deps
  in
  let compile_component id pers_id args body =
    let funct =
      Lprim(Pfield 0, [Lprim(Pgetglobal pers_id, [], Location.none)],
            Location.none) in
    Llet(Strict, Pgenval, id,
         Lapply{ap_should_be_tailcall=false;
                ap_loc=Location.none;
                ap_func=funct;
                ap_args=args;
                ap_inlined=Default_inline;
                ap_specialised=Default_specialise},
         body)
  in
  let shape, fvs = init_shape_package (List.map fst components) in
  let funct body =
    let params = List.filter_map (fun id ->
        if List.exists (function
              (PM_intf, _) -> assert false
            | (PM_impl { member_cu }, _) ->
                Ident.name id = Compilation_unit.full_path_as_string member_cu)
            components
        then
          None
        else
          Some (id, Pgenval))
        ids
    in
    let funct_code, _ =
      if Persistent_env.Current_unit.in_recursive_pack () then
        transl_recursive_implementation module_id shape params body
      else transl_recursive_implementation_strict params body
    in
    funct_code
  in
  let code =
    (if !Clflags.make_recursive_package then
      compile_recunits components recdeps Location.none
        (bind_components components)
    else
      List.fold_right (fun (comp, id) acc ->
          match comp with
            PM_intf -> assert false
          | PM_impl { member_cu; member_recursive_dependencies } ->
              let pers_id = persistent_id member_cu in
              let args = generate_args member_recursive_dependencies in
              compile_component id pers_id args acc)
        components
        (Lprim(Pmakeblock(0, Immutable, None),
               List.map (fun (_, id) -> Lvar id) components, Location.none)))
    |> funct
  in
  code, Some (shape, fvs)

let transl_recursive_subpackage module_id components recdeps bind_components =
  let funct_body, recursive =
    transl_recursive_subpackage_gen module_id components recdeps bind_components
  in
  let funct_id = Ident.create_local ("functor_mod_sub") in
  Llet (Strict, Pgenval, funct_id, funct_body,
        Lprim(Pmakeblock(0, Immutable, None), [Lvar funct_id],
              Location.none)),
  1,
  recursive

let transl_recursive_package module_id components recdeps size bind_components =
  let components =
    List.map (function
          PM_intf -> assert false
        | PM_impl { member_cu; _} as comp  ->
            comp,
            Ident.create_local (Compilation_unit.full_path_as_string member_cu))
      components in
  if Persistent_env.Current_unit.recursive_prefixes () <> [] then
    transl_recursive_subpackage module_id components recdeps bind_components
  else
    let code =
      compile_recunits components recdeps Location.none
        (bind_components components)
    in
    let recursive =
      if Persistent_env.Current_unit.recursive_prefixes () <> [] then
        let shape, fvs = init_shape_package (List.map fst components) in
        Some (shape, fvs)
      else
        None
    in
    code,
    size,
    recursive

let transl_package_flambda components module_id recdeps coercion =
  let size =
    match coercion with
    | Tcoerce_none -> List.length components
    | Tcoerce_structure (l, _) -> List.length l
    | Tcoerce_functor _
    | Tcoerce_primitive _
    | Tcoerce_alias _ -> assert false
  in
  let code, size, recursive =
    if Persistent_env.Current_unit.recursive_prefixes () <> []
     || !Clflags.make_recursive_package then
      transl_recursive_package module_id components recdeps size
        (fun components ->
           Lprim(Pmakeblock(0, Immutable, None),
                 List.map (fun (_, id) -> Lvar id) components, Location.none)
           |> apply_coercion Location.none Strict coercion)
    else
      Lprim(Pmakeblock(0, Immutable, None),
            List.map get_component components,
            Location.none)
      |> apply_coercion Location.none Strict coercion,
      size,
      None
  in
  { code;
    main_module_block_size = size;
    module_ident = module_id;
    required_globals = required_globals ~flambda:true code;
    recursive;
  }

let transl_package components target_name recdeps coercion =
  let module_name = transl_current_module_ident (Ident.name target_name) in
  let size =
    match coercion with
    | Tcoerce_none -> List.length components
    | Tcoerce_structure (l, _) -> List.length l
    | Tcoerce_functor _
    | Tcoerce_primitive _
    | Tcoerce_alias _ -> assert false
  in
  let body, size, recursive =
    if !Clflags.make_recursive_package then
      transl_recursive_package target_name components recdeps size
        (fun components ->
           Lprim(Pmakeblock(0, Immutable, None),
                 List.map (fun (_, id) -> Lvar id) components, Location.none))
    else
      Lprim(Pmakeblock(0, Immutable, None),
            List.map get_component components, Location.none),
      size,
      None
  in
  { code =
      Lprim(Psetglobal module_name,
            [apply_coercion Location.none Strict coercion body],
            Location.none);
    main_module_block_size = size;
    module_ident = target_name;
    required_globals = required_globals ~flambda:true body;
    recursive;
  }
  (*
  let components =
    match coercion with
      Tcoerce_none ->
        List.map get_component component_names
    | Tcoerce_structure (pos_cc_list, id_pos_list) ->
              (* ignore id_pos_list as the ids are already bound *)
        let g = Array.of_list component_names in
        List.map
          (fun (pos, cc) -> apply_coercion Strict cc (get_component g.(pos)))
          pos_cc_list
    | _ ->
        assert false in
  Lprim(Psetglobal target_name, [Lprim(Pmakeblock(0, Immutable), components)])
   *)

let transl_store_recursive_subpackage module_id components recdeps bind =
  let funct_body, recursive =
    transl_recursive_subpackage_gen module_id components recdeps bind in
  let funct_id = Ident.create_local "functor_mod_store_sub" in
  Llet (Strict, Pgenval, funct_id, funct_body,
        Lprim(Psetfield(0, Pointer, Root_initialization),
              [Lprim(Pgetglobal module_id, [], Location.none);
               Lvar funct_id],
              Location.none)),
  1,
  recursive

let transl_store_recursive_package
    module_id components recdeps size bind_components =
  let components =
    List.map (function
          PM_intf -> assert false
        | PM_impl { member_cu; _} as comp  ->
            comp,
            Ident.create_local (Compilation_unit.full_path_as_string member_cu))
      components in
  if !Clflags.recursive_packages <> [] then
    transl_store_recursive_subpackage
      module_id components recdeps bind_components
  else
    compile_recunits components recdeps Location.none
      (bind_components components),
    size,
    None

let transl_store_package components target_name recdeps coercion =
  let rec make_sequence fn pos arg =
    match arg with
      [] -> lambda_unit
    | hd :: tl -> Lsequence(fn pos hd, make_sequence fn (pos + 1) tl) in
  match coercion with
    Tcoerce_none ->
      let bind get_component components =
        make_sequence
          (fun pos id ->
             Lprim(Psetfield(pos, Pointer, Root_initialization),
                   [Lprim(Pgetglobal target_name, [], Location.none);
                    get_component id],
                   Location.none))
          0 components
      in
      let size = List.length components in
      let code, size, recursive =
        if !Clflags.make_recursive_package
           || Persistent_env.Current_unit.recursive_prefixes () <> [] then
          transl_store_recursive_package
            target_name components recdeps size (bind (fun (_, id) -> Lvar id))
        else
          bind get_component components,
          size,
          None
      in
      { code;
        main_module_block_size = size;
        module_ident = target_name;
        required_globals = required_globals ~flambda:true code;
        recursive;
      }

  | Tcoerce_structure (pos_cc_list, _id_pos_list) ->
      let bind get_component components =
        Lprim(Pmakeblock(0, Immutable, None),
              List.map get_component components,
              Location.none)
      in
      let size = List.length pos_cc_list in
      let components, size, recursive =
        if !Clflags.make_recursive_package
           || Persistent_env.Current_unit.recursive_prefixes () <> [] then
          transl_store_recursive_package
            target_name components recdeps size (bind (fun (_, id) -> Lvar id))
        else
          bind get_component components,
          size,
          None
      in
      let blk = Ident.create_local "block" in
      let code =
        Llet (Strict, Pgenval, blk,
              apply_coercion Location.none Strict coercion components,
              make_sequence
                (fun pos _id ->
                   Lprim(Psetfield(pos, Pointer, Root_initialization),
                         [Lprim(Pgetglobal target_name, [], Location.none);
                          Lprim(Pfield pos, [Lvar blk], Location.none)],
                         Location.none))
                0 pos_cc_list) in

      { code;
        main_module_block_size = size;
        module_ident = target_name;
        required_globals = required_globals ~flambda:true code;
        recursive;
      }
  (*
              (* ignore id_pos_list as the ids are already bound *)
      let id = Array.of_list component_names in
      (List.length pos_cc_list,
       make_sequence
         (fun dst (src, cc) ->
           Lprim(Psetfield(dst, false),
                 [Lprim(Pgetglobal target_name, []);
                  apply_coercion Strict cc (get_component id.(src))]))
         0 pos_cc_list)
  *)
  | _ -> assert false

(* Error report *)

open Format

let print_cycle ppf cycle =
  let print_ident ppf (x,_) = Format.pp_print_string ppf (Ident.name x) in
  let pp_sep ppf () = fprintf ppf "@ -> " in
  Format.fprintf ppf "%a%a%s"
    (Format.pp_print_list ~pp_sep print_ident) cycle
    pp_sep ()
    (Ident.name @@ fst @@ List.hd cycle)
(* we repeat the first element to make the cycle more apparent *)

let explanation_submsg (id, unsafe_info) =
  match unsafe_info with
  | Unnamed -> assert false (* can't be part of a cycle. *)
  | Info {reason;info_loc;subid} ->
      let print fmt =
        let printer = Format.dprintf fmt (Ident.name id) (Ident.name subid) in
        Location.mkloc printer info_loc in
      match reason with
      | Unsafe_module_binding ->
          print "Module %s defines an unsafe module, %s ."
      | Unsafe_functor -> print "Module %s defines an unsafe functor, %s ."
      | Unsafe_typext ->
          print "Module %s defines an unsafe extension constructor, %s ."
      | Unsafe_non_function -> print "Module %s defines an unsafe value, %s ."

let report_error loc = function
  | Circular_dependency cycle ->
      let[@manual.ref "s:recursive-modules"] chapter, section = 8, 2 in
      Location.errorf ~loc ~sub:(List.map explanation_submsg cycle)
        "Cannot safely evaluate the definition of the following cycle@ \
         of recursively-defined modules:@ %a.@ \
         There are no safe modules in this cycle@ (see manual section %d.%d)."
        print_cycle cycle chapter section
  | Conflicting_inline_attributes ->
      Location.errorf "@[Conflicting 'inline' attributes@]"

let () =
  Location.register_error_of_exn
    (function
      | Error (loc, err) -> Some (report_error loc err)
      | _ ->
        None
    )

let reset () =
  primitive_declarations := [];
  transl_store_subst := Ident.Map.empty;
  aliased_idents := Ident.empty;
  Env.reset_required_globals ();
  Translprim.clear_used_primitives ()
