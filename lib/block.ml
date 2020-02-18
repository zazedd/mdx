(*
 * Copyright (c) 2018 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Result
open Compat

module Header = struct
  type t = Shell | OCaml | Other of string

  let pp ppf = function
    | Shell -> Fmt.string ppf "sh"
    | OCaml -> Fmt.string ppf "ocaml"
    | Other s -> Fmt.string ppf s

  let of_string = function
    | "" -> None
    | "sh" | "bash" -> Some Shell
    | "ocaml" -> Some OCaml
    | s -> Some (Other s)
end

type section = int * string

type cram_value = {
  pad : int;
  tests : Cram.t list;
  non_det : Label.non_det option;
}

type ocaml_value = {
  env : string;
  non_det : Label.non_det option;
}

type toplevel_value = {
  phrases : Toplevel.t list;
  env : string;
  non_det : Label.non_det option;
}

type include_value = {
  file_included : string;
  part_included : string option;
}

type value =
  | Raw
  | OCaml of ocaml_value
  | Error of string list
  | Cram of cram_value
  | Toplevel of toplevel_value
  | Include of include_value

type t = {
  line : int;
  file : string;
  section : section option;
  dir : string option;
  source_trees : string list;
  required_packages : string list;
  labels : Label.t list;
  header : Header.t option;
  contents : string list;
  skip : bool;
  version : (Label.Relation.t * Ocaml_version.t) option;
  set_variables : (string * string) list;
  value : value;
}

let line t = t.line

let filename t = t.file

let section t = t.section

let labels t = t.labels

let header t = t.header

let contents t = t.contents

let value t = t.value

let dump_string ppf s = Fmt.pf ppf "%S" s

let dump_section = Fmt.(Dump.pair int string)

let dump_value ppf = function
  | Raw -> Fmt.string ppf "Raw"
  | OCaml _ -> Fmt.string ppf "OCaml"
  | Error e -> Fmt.pf ppf "Error %a" Fmt.(Dump.list dump_string) e
  | Cram { pad; tests; _ } ->
    Fmt.pf ppf "@[Cram@ {pad=%d;@ tests=%a}@]"
      pad Fmt.(Dump.list Cram.dump) tests
  | Toplevel { phrases= tests; _ } ->
    Fmt.pf ppf "@[Toplevel %a@]" Fmt.(Dump.list Toplevel.dump) tests
  | Include _ -> Fmt.string ppf "Include"

let dump ppf t =
  Fmt.pf ppf
    "{@[file: %s;@ line: %d;@ section: %a;@ labels: %a;@ header: %a;@\n\
    \        contents: %a;@ value: %a@]}" (filename t) (line t)
    Fmt.(Dump.option dump_section)
    (section t)
    Fmt.Dump.(list Label.pp)
    (labels t)
    Fmt.(Dump.option Header.pp)
    (header t)
    Fmt.(Dump.list dump_string)
    (contents t) dump_value (value t)

let pp_lines syntax =
  let pp =
    match syntax with Some Syntax.Cram -> Fmt.fmt "  %s" | _ -> Fmt.string
  in
  Fmt.(list ~sep:(unit "\n") pp)

let pp_contents ?syntax ppf t = Fmt.pf ppf "%a\n" (pp_lines syntax) (contents t)

let pp_footer ?syntax ppf () =
  match syntax with Some Syntax.Cram -> () | _ -> Fmt.string ppf "```\n"

let pp_labels ppf = function
  | [] -> ()
  | l -> Fmt.pf ppf " %a" Fmt.(list ~sep:(unit ",") Label.pp) l

let pp_header ?syntax ppf t =
  match syntax with
  | Some Syntax.Cram -> (
      match labels t with
      | [] -> ()
      | [Non_det None] -> Fmt.pf ppf "<-- non-deterministic\n"
      | [Non_det (Some Nd_output)] ->
        Fmt.pf ppf "<-- non-deterministic output\n"
      | [Non_det (Some Nd_command)] ->
        Fmt.pf ppf "<-- non-deterministic command\n"
      | _ -> failwith "cannot happen: checked during parsing" )
  | _ ->
    Fmt.pf ppf "```%a%a\n" Fmt.(option Header.pp) (header t) pp_labels
      (labels t)

let pp_error ppf b =
  match value b with
  | Error e -> List.iter (fun e -> Fmt.pf ppf ">> @[<h>%a@]@." Fmt.words e) e
  | _ -> ()

let pp ?syntax ppf b =
  pp_header ?syntax ppf b;
  pp_error ppf b;
  pp_contents ?syntax ppf b;
  pp_footer ?syntax ppf ()

let directory t = t.dir

let file t = match value t with Include t -> Some t.file_included | _ -> None

let version t = t.version

let source_trees t = t.source_trees

let non_det t =
  match value t with
  | OCaml b -> b.non_det
  | Cram b -> b.non_det
  | Toplevel b -> b.non_det
  | Error _ | Include _ | Raw -> None

let skip t = t.skip

let environment t =
  match value t with
  | OCaml b -> b.env
  | Toplevel b -> b.env
  | Cram _ | Error _ | Include _ | Raw -> "default"

let set_variables t = t.set_variables

let unset_variables t =
  List.filter_map (function Label.Unset x -> Some x | _ -> None) (labels t)

let explicit_required_packages t = t.required_packages

let require_re =
  let open Re in
  seq [ str "#require \""; group (rep1 any); str "\"" ]

let require_from_line line =
  let open Util.Result.Infix in
  let re = Re.compile require_re in
  match Re.exec_opt re line with
  | None -> Ok Library.Set.empty
  | Some group ->
      let matched = Re.Group.get group 1 in
      let libs_str = String.split_on_char ',' matched in
      Util.Result.List.map ~f:Library.from_string libs_str >>| fun libs ->
      Library.Set.of_list libs

let require_from_lines lines =
  let open Util.Result.Infix in
  Util.Result.List.map ~f:require_from_line lines >>| fun libs ->
  List.fold_left Library.Set.union Library.Set.empty libs

let required_libraries t =
  match value t with
  | Toplevel _ -> require_from_lines (contents t)
  | Raw | OCaml _ | Error _ | Cram _ | Include _ -> Ok Library.Set.empty

let guess_ocaml_kind contents =
  let rec aux = function
    | [] -> `Code
    | h :: t ->
        let h = String.trim h in
        if h = "" then aux t
        else if String.length h > 1 && h.[0] = '#' then `Toplevel
        else `Code
  in
  aux contents

let ends_by_semi_semi c = match List.rev c with
  | h::_ ->
      let len = String.length h in
      len > 2 && h.[len-1] = ';' && h.[len-2] = ';'
  | _ -> false

let pp_line_directive ppf (file, line) = Fmt.pf ppf "#%d %S" line file

let line_directive = Fmt.to_to_string pp_line_directive

let executable_contents b =
  let contents =
      match value b with
      | OCaml _ -> contents b
      | Error _ | Raw | Cram _ | Include _ -> []
      | Toplevel { phrases; _ } ->
        List.flatten (
          List.map (fun t ->
              match Toplevel.command t with
              | [] -> []
              | cs ->
                let mk s = String.make (t.hpad+2) ' ' ^ s in
                line_directive (filename b, t.line) :: List.map mk cs
            ) phrases )
  in
  if contents = [] || ends_by_semi_semi contents then contents
  else contents @ [ ";;" ]

let version_enabled t =
  match Ocaml_version.of_string Sys.ocaml_version with
  | Ok curr_version -> (
      match version t with
      | Some (op, v) ->
          Label.Relation.compare op (Ocaml_version.compare curr_version v) 0
      | None -> true )
  | Error (`Msg e) -> Fmt.failwith "invalid OCaml version: %s" e

let get_label f (labels : Label.t list) = Util.List.find_map f labels

let check_not_set msg = function
  | Some _ -> Util.Result.errorf msg
  | None -> Ok ()

let mk ~line ~file ~section ~labels ~header ~contents =
  let non_det = get_label (function Non_det x -> x | _ -> None) labels in
  let part = get_label (function Part x -> Some x | _ -> None) labels in
  let env = get_label (function Env x -> Some x | _ -> None) labels in
  let dir = get_label (function Dir x -> Some x | _ -> None) labels in
  let skip = List.exists (function Label.Skip -> true | _ -> false) labels in
  let version =
    get_label (function Version (x, y) -> Some (x, y) | _ -> None) labels
  in
  let source_trees =
    List.filter_map (function Label.Source_tree x -> Some x | _ -> None) labels
  in
  let required_packages =
    List.filter_map
      (function Label.Require_package x -> Some x | _ -> None) labels
  in
  let set_variables =
    List.filter_map
      (function Label.Set (v, x) -> Some (v, x) | _ -> None) labels
  in
  let open Util.Result.Infix in
  (match get_label (function File x -> Some x | _ -> None) labels with
  | Some file_included -> (
      check_not_set
        "`non-deterministic` label cannot be used with a `file` label." non_det
      >>= fun () ->
      check_not_set "`env` label cannot be used with a `file` label." env
      >>= fun () ->
      match part with
      | Some part -> (
          match header with
          | Some Header.OCaml ->
            Ok (Include { file_included; part_included= Some part })
          | _ ->
            Util.Result.errorf
              "`part` is not supported for non-OCaml code blocks." )
      | None -> Ok (Include { file_included; part_included= None }) )
  | None ->
    check_not_set "`part` label requires a `file` label." part >>= fun () ->
    match header with
    | Some Header.Shell ->
      check_not_set "`env` label cannot be used with a `shell` header." env
      >>= fun () ->
      let pad, tests = Cram.of_lines contents in
      Ok (Cram { pad; tests; non_det })
    | Some Header.OCaml -> (
        let env = match env with Some e -> e | None -> "default" in
        match guess_ocaml_kind contents with
        | `Code -> Ok (OCaml { env; non_det })
        | `Toplevel ->
          let phrases = Toplevel.of_lines ~file ~line contents in
          Ok (Toplevel { phrases; env; non_det }) )
    | _ -> Ok Raw)
  >>= fun value ->
  Ok
    { line; file; section; dir; source_trees; required_packages; labels; header;
      contents; skip; version; set_variables; value }

let is_active ?section:s t =
  let active =
    match s with
    | Some p -> (
        match section t with
        | Some s -> Re.execp (Re.Perl.compile_pat p) (snd s)
        | None -> Re.execp (Re.Perl.compile_pat p) "" )
    | None -> true
  in
  active && version_enabled t && not (skip t)
