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

let src = Logs.Src.create "ocaml-mdx"

module Lexer_mdx = Lexer_mdx
module Lexer_tex = Lexer_tex
module Log = (val Logs.src_log src : Logs.LOG)
module Output = Output
module Cram = Cram
module Deprecated = Deprecated
module Document = Document
module Toplevel = Toplevel
module Part = Part
module Block = Block
module Mli_parser = Mli_parser
module Compat = Compat
module Util = Util
module Prelude = Prelude
module Syntax = Syntax
module Label = Label
module Dep = Dep
module Ocaml_env = Ocaml_env
module Stable_printer = Stable_printer
include Document
open Util.Result.Infix

let section_of_line = function
  | Section s -> Some s
  | Text _ -> None
  | Block b -> b.section

let filter_section re (t : t) =
  match
    List.filter
      (fun l ->
        match section_of_line l with
        | None -> false
        | Some (_, s) -> Re.execp re s)
      t
  with
  | [] -> None
  | l -> Some l

let parse l =
  let results =
    List.map
      (function
        | `Text t -> Ok (Text t)
        | `Section s -> Ok (Section s)
        | `Block rb ->
            let* b = Block.from_raw rb in
            Ok (Block b))
      l
  in
  let ok, errors = Util.Result.List.split results in
  match errors with [] -> Ok ok | _ -> Error (List.concat errors)

let parse_lexbuf syntax Misc.{ string; lexbuf } =
  match syntax with
  | Syntax.Mli -> Mli_parser.parse_mli string
  | Syntax.Mld -> Mli_parser.parse_mld string
  | Latex ->
      Util.Result.to_error_list @@ Lexer_tex.latex_token lexbuf >>= parse
  | Markdown ->
      Util.Result.to_error_list @@ Lexer_mdx.markdown_token lexbuf >>= parse
  | Cram -> Util.Result.to_error_list @@ Lexer_mdx.cram_token lexbuf >>= parse

let parse_file syntax f = Misc.load_file ~filename:f |> parse_lexbuf syntax

let of_string syntax s =
  match syntax with
  | Syntax.Mli -> Mli_parser.parse_mli s
  | Syntax.Mld -> Mli_parser.parse_mld s
  | Syntax.Latex | Syntax.Markdown | Syntax.Cram ->
      Misc.{ lexbuf = Lexing.from_string s; string = s } |> parse_lexbuf syntax

let dump_line ppf (l : line) =
  match l with
  | Block b -> Fmt.pf ppf "Block %a" Block.dump b
  | Section (d, s) -> Fmt.pf ppf "Section (%d, %S)" d s
  | Text s -> Fmt.pf ppf "Text %S" s

let dump = Fmt.Dump.list dump_line

type expect_result = Identical | Differs

let run_str ~syntax ~f file =
  let l = Misc.load_file ~filename:file in
  let+ items = parse_lexbuf syntax l in
  Log.debug (fun l -> l "run @[%a@]" dump items);
  let corrected = f l.string items in
  let has_changed = corrected <> l.string in
  let result = if has_changed then Differs else Identical in
  (result, corrected)

let write_file ~outfile content =
  let oc = open_out_bin outfile in
  output_string oc content;
  close_out oc

let run_to_stdout ?(syntax = Syntax.Markdown) ~f infile =
  let+ _, corrected = run_str ~syntax ~f infile in
  print_string corrected

let run_to_file ?(syntax = Syntax.Markdown) ~f ~outfile infile =
  let+ _, corrected = run_str ~syntax ~f infile in
  write_file ~outfile corrected

let run ?(syntax = Syntax.Markdown) ?(force_output = false) ~f infile =
  let outfile = infile ^ ".corrected" in
  let+ test_result, corrected = run_str ~syntax ~f infile in
  match (force_output, test_result) with
  | true, _ | false, Differs -> write_file ~outfile corrected
  | false, Identical -> if Sys.file_exists outfile then Sys.remove outfile
