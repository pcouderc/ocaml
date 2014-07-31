(***********************************************************************)
(*                                                                     *)
(*                                OCaml                                *)
(*                                                                     *)
(*            Xavier Leroy, projet Cristal, INRIA Rocquencourt         *)
(*                                                                     *)
(*  Copyright 1996 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under the terms of the Q Public License version 1.0.               *)
(*                                                                     *)
(***********************************************************************)

(* Compilation environments for compilation units *)

open Config
open Misc
open Clambda
open Cmx_format

type error =
    Not_a_unit_info of string
  | Corrupted_unit_info of string
  | Illegal_renaming of string * string * string

exception Error of error

let global_infos_table =
  (Hashtbl.create 17 : ((string * Longident.t option), unit_infos option) Hashtbl.t)

module CstMap =
  Map.Make(struct
    type t = Clambda.ustructured_constant
    let compare = Clambda.compare_structured_constants
    (* PR#6442: it is incorrect to use Pervasives.compare on values of type t
       because it compares "0.0" and "-0.0" equal. *)
  end)

type structured_constants =
  {
    strcst_shared: string CstMap.t;
    strcst_all: (string * Clambda.ustructured_constant) list;
  }

let structured_constants_empty  =
  {
    strcst_shared = CstMap.empty;
    strcst_all = [];
  }

let structured_constants = ref structured_constants_empty


let exported_constants = Hashtbl.create 17

let current_unit =
  { ui_name = "";
    ui_namespace = None;
    ui_symbol = "";
    ui_defines = [];
    ui_imports_cmi = [];
    ui_imports_cmx = [];
    ui_approx = Value_unknown;
    ui_curry_fun = [];
    ui_apply_fun = [];
    ui_send_fun = [];
    ui_functor_parts = [];
    ui_functor_args = [];
    ui_force_link = false }

let symbol_of_namespace = function
    None -> ""
  | Some ns -> "@" ^ String.concat "$" @@ Longident.flatten ns

let symbolname_for_pack ?(ns=None) pack name =
  if !Clflags.ns_debug then
    Format.printf "Calling symbolname_for_pack with %s and ns: %s@."
      name (symbol_of_namespace ns);
  match pack with
  | None -> name ^ symbol_of_namespace ns
  | Some p ->
      let b = Buffer.create 64 in
      let first = ref true in
      for i = 0 to String.length p - 1 do
        match p.[i] with
        | '.' when !first ->
            first := false;
            Buffer.add_string b (symbol_of_namespace ns);
            Buffer.add_string b "__"
        | '.' -> Buffer.add_string b "__"
        |  c  -> Buffer.add_char b c
      done;
      if !first then
        Buffer.add_string b (symbol_of_namespace ns);
      Buffer.add_string b "__";
      Buffer.add_string b name;
      Buffer.contents b


let reset ?packname name =
  if !Clflags.ns_debug then
    Format.printf "Compilenv.reset called with name: %s@." name;
  Hashtbl.clear global_infos_table;
  let symbol = symbolname_for_pack packname name in
  if !Clflags.ns_debug then
    Format.printf "Symbol: %s@." symbol;
  current_unit.ui_name <- name;
  current_unit.ui_symbol <- symbol;
  current_unit.ui_defines <- [symbol];
  current_unit.ui_imports_cmi <- [];
  current_unit.ui_imports_cmx <- [];
  current_unit.ui_curry_fun <- [];
  current_unit.ui_apply_fun <- [];
  current_unit.ui_send_fun <- [];
  current_unit.ui_force_link <- false;
  Hashtbl.clear exported_constants;
  structured_constants := structured_constants_empty

let current_unit_infos () =
  current_unit

let current_unit_name () =
  current_unit.ui_name

let set_current_unit_namespace ?packname ns =
  let curr_symb = current_unit.ui_symbol in
  (* let update_symb symb = function *)
  (*     None -> symb *)
  (*   | Some ns -> symb ^ "@" ^ Longident.string_of_longident ns *)
  (* in *)
  (* let symbol = match packname with *)
  (*     None -> *)
  (*       if !Clflags.ns_debug then *)
  (*         Format.printf "Not for pack@."; *)
  (*       update_symb curr_symb ns *)
  (*   | Some p -> *)
  (*       if !Clflags.ns_debug then *)
  (*         Format.printf "Forpack %s@." p; *)
  (*       symbolname_for_pack (Some (update_symb p ns)) current_unit.ui_name *)
  (* in *)
  let symbol = symbolname_for_pack ~ns packname current_unit.ui_name in
  current_unit.ui_symbol <- symbol;
  current_unit.ui_namespace <- ns;
  current_unit.ui_defines <-
    List.map (fun n ->
        if !Clflags.ns_debug then
          Format.printf "%s corresponds to %s ?@." n curr_symb;
        if n = curr_symb then symbol else n)
      current_unit.ui_defines

let make_symbol ?(unitname = current_unit.ui_symbol) idopt =
  let prefix = "caml" ^ unitname in
  (* if !Clflags.ns_debug then *)
  (*   Format.printf "Compilenv.make_symbol, prefix: %s@." prefix; *)
  match idopt with
  | None -> prefix
  | Some id -> prefix ^ "__" ^ id

let symbol_in_current_unit name =
  let prefix = "caml" ^ current_unit.ui_symbol in
  name = prefix ||
  (let lp = String.length prefix in
   String.length name >= 2 + lp
   && String.sub name 0 lp = prefix
   && name.[lp] = '_'
   && name.[lp + 1] = '_')

let read_unit_info filename =
  let ic = open_in_bin filename in
  try
    let buffer = really_input_string ic (String.length cmx_magic_number) in
    if buffer <> cmx_magic_number then begin
      close_in ic;
      raise(Error(Not_a_unit_info filename))
    end;
    let ui = (input_value ic : unit_infos) in
    let crc = Digest.input ic in
    close_in ic;
    (ui, crc)
  with End_of_file | Failure _ ->
    close_in ic;
    raise(Error(Corrupted_unit_info(filename)))

let read_library_info filename =
  let ic = open_in_bin filename in
  let buffer = really_input_string ic (String.length cmxa_magic_number) in
  if buffer <> cmxa_magic_number then
    raise(Error(Not_a_unit_info filename));
  let infos = (input_value ic : library_infos) in
  close_in ic;
  infos


(* Read and cache info on global identifiers *)

let get_global_info global_ident = (
  let modname = Ident.shortname global_ident in
  let ns = Longident.from_optstring @@ Ident.extract_namespace global_ident in
  let subdir = Env.longident_to_filepath ns in
  if modname = current_unit.ui_name && ns = current_unit.ui_namespace then
    Some current_unit
  else begin
    try
      Hashtbl.find global_infos_table (modname, ns)
    with Not_found ->
      let (infos, crc) =
        try
          let filename =
            find_in_path_uncap ~subdir !load_path (modname ^ ".cmx") in
          let (ui, crc) = read_unit_info filename in
          if ui.ui_name <> modname then
            raise(Error(Illegal_renaming(modname, ui.ui_name, filename)));
          (Some ui, Some crc)
        with Not_found ->
          if !Clflags.ns_debug then
            Format.printf "%s in namespace %s not found@." modname subdir;
          (None, None) in
      current_unit.ui_imports_cmx <-
        (modname, ns, crc) :: current_unit.ui_imports_cmx;
      Hashtbl.add global_infos_table (modname, ns) infos;
      infos
  end
)

let cache_unit_info ui =
  Hashtbl.add global_infos_table (ui.ui_name, ui.ui_namespace) (Some ui)

(* Return the approximation of a global identifier *)

let toplevel_approx = Hashtbl.create 16

let record_global_approx_toplevel id =
  Hashtbl.add toplevel_approx current_unit.ui_name current_unit.ui_approx

let global_approx id =
  if Ident.is_predef_exn id || Ident.is_functor_arg id then Value_unknown
  else try Hashtbl.find toplevel_approx (Ident.name id)
  with Not_found ->
    match get_global_info id with
      | None -> Value_unknown
      | Some ui -> ui.ui_approx

(* Return the symbol used to refer to a global identifier *)

let symbol_for_global id =
  if Ident.is_predef_exn id then
    "caml_exn_" ^ Ident.name id
  else begin
    if !Clflags.ns_debug then
      Format.printf "Compilenv.get_global_info, id:%s@." (Ident.name id);
    match get_global_info id with
    | None -> make_symbol ~unitname:(Ident.name id) None
    | Some ui ->
        if !Clflags.ns_debug then
          Format.printf "Compilenv.symbol_for_global, Some branch, symbol: %s@."
            ui.ui_symbol;
        make_symbol ~unitname:ui.ui_symbol None
  end

(* Register the approximation of the module being compiled *)

let set_global_approx approx =
  current_unit.ui_approx <- approx

(* Record that a currying function or application function is needed *)

let need_curry_fun n =
  if not (List.mem n current_unit.ui_curry_fun) then
    current_unit.ui_curry_fun <- n :: current_unit.ui_curry_fun

let need_apply_fun n =
  if not (List.mem n current_unit.ui_apply_fun) then
    current_unit.ui_apply_fun <- n :: current_unit.ui_apply_fun

let need_send_fun n =
  if not (List.mem n current_unit.ui_send_fun) then
    current_unit.ui_send_fun <- n :: current_unit.ui_send_fun

(* Write the description of the current unit *)

let write_unit_info info filename =
  (* let dir = Filename.concat !Clflags.root @@ *)
  (*   Env.longident_to_filepath info.ui_namespace in *)
  let filename = Env.output_name filename info.ui_namespace in
  let oc = open_out_bin filename in
  output_string oc cmx_magic_number;
  output_value oc info;
  flush oc;
  let crc = Digest.file filename in
  Digest.output oc crc;
  close_out oc

let save_unit_info filename =
  if !Clflags.ns_debug then
    Format.printf "in Compilenv.save_unit_info@.";
  current_unit.ui_imports_cmi <- Env.imports();
  current_unit.ui_functor_args <- Env.get_functor_args();
  current_unit.ui_functor_parts <- Env.get_functor_parts();
  write_unit_info current_unit filename;
  if !Clflags.ns_debug then
    Format.printf "Out of Compilenv.save_unit_info@."



let const_label = ref 0

let new_const_label () =
  incr const_label;
  !const_label

let new_const_symbol () =
  incr const_label;
  make_symbol (Some (string_of_int !const_label))

let snapshot () = !structured_constants
let backtrack s = structured_constants := s

let new_structured_constant cst ~shared =
  let {strcst_shared; strcst_all} = !structured_constants in
  if shared then
    try
      CstMap.find cst strcst_shared
    with Not_found ->
      let lbl = new_const_symbol() in
      structured_constants :=
        {
          strcst_shared = CstMap.add cst lbl strcst_shared;
          strcst_all = (lbl, cst) :: strcst_all;
        };
      lbl
  else
    let lbl = new_const_symbol() in
    structured_constants :=
      {
        strcst_shared;
        strcst_all = (lbl, cst) :: strcst_all;
      };
    lbl

let add_exported_constant s =
  Hashtbl.replace exported_constants s ()

let structured_constants () =
  List.map
    (fun (lbl, cst) ->
       (lbl, Hashtbl.mem exported_constants lbl, cst)
    ) (!structured_constants).strcst_all

(* Error report *)

open Format

let report_error ppf = function
  | Not_a_unit_info filename ->
      fprintf ppf "%a@ is not a compilation unit description."
        Location.print_filename filename
  | Corrupted_unit_info filename ->
      fprintf ppf "Corrupted compilation unit description@ %a"
        Location.print_filename filename
  | Illegal_renaming(name, modname, filename) ->
      fprintf ppf "%a@ contains the description for unit\
                   @ %s when %s was expected"
        Location.print_filename filename name modname

let () =
  Location.register_error_of_exn
    (function
      | Error err -> Some (Location.error_of_printer_file report_error err)
      | _ -> None
    )
