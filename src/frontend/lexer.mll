{
  open Types
  open Parser

  exception LexError of Range.t * string

  (*
   * The SATySFi lexer is stateful; the transitions are:
   * | to \ from |program|block |inline|active |  math  |
   * |-----------|-------|------|------|-------|--------|
   * |  program  | (   ) |      |      | (   ) | !(   ) |
   * |           | (| |) |      |      | (| |) | !(| |) |
   * |           | [   ] |      |      | [   ] | ![   ] |
   * |  block    | '<  > | <  > | <  > | <     | !<   > |
   * |  inline   | {   } | {  } | {  } | {     | !{   } |
   * |  active   |       | +x ; | \x ; |       |        |
   * |           |       | #x ; | #x ; |       |        |
   * |  math     | ${  } |      | ${ } |       | {    } |
   *
   * Note that the active-block and active-inline transitions are one-way.
   *)
  type lexer_state =
    | ProgramState (* program mode *)
    | VerticalState (* block mode *)
    | HorizontalState (* inline mode *)
    | ActiveState (* active mode *)
    | MathState (* math mode *)

  let ignore_space : bool ref = ref true
  let quote_range : Range.t ref = ref (Range.dummy "")
  let quote_length : int ref = ref 0
  let literal_buffer : Buffer.t = Buffer.create 256
  let stack : lexer_state Stack.t = Stack.create ()

  let get_pos lexbuf =
    let posS = Lexing.lexeme_start_p lexbuf in
    let posE = Lexing.lexeme_end_p lexbuf in
    let lnum = posS.Lexing.pos_lnum in
    let cnumS = posS.Lexing.pos_cnum - posS.Lexing.pos_bol in
    let cnumE = posE.Lexing.pos_cnum - posE.Lexing.pos_bol in
      Range.make lnum cnumS cnumE

  let report_error lexbuf errmsg =
    let rng = get_pos lexbuf in
      raise (LexError(rng, errmsg))

  let next_state () =
    Stack.top stack

  let pop lexbuf errmsg =
    if Stack.length stack > 1 then
      Stack.pop stack |> ignore
    else
      report_error lexbuf errmsg

  let push state =
    Stack.push state stack

  let increment_line lexbuf =
    begin
      Lexing.new_line lexbuf;
    end


  let rec increment_line_for_each_break lexbuf str =
    let len = String.length str in
    let rec aux num =
      if num >= len then () else
        begin
          begin
            match String.get str num with
            | ( '\n' | '\r' ) -> increment_line lexbuf
            | _               -> ()
          end;
          aux (num + 1)
        end
    in
      aux 0


  let initialize state =
    begin
      ignore_space := true;
      quote_range := Range.dummy "";
      quote_length := 0;
      literal_buffer |> Buffer.clear;
      stack |> Stack.clear;
      Stack.push state stack;
    end


  let reset_to_progexpr () =
    initialize ProgramState


  let reset_to_vertexpr () =
    initialize VerticalState


  let split_module_list tokstr =
    let rec aux imax i acclst accstr =
      if i >= imax then (List.rev acclst, accstr) else
        match String.get tokstr i with
        | '.' -> aux imax (i + 1) (accstr :: acclst) ""
        | c   -> aux imax (i + 1) acclst (accstr ^ (String.make 1 c))
    in
      aux (String.length tokstr) 0 [] ""
}

let space = [' ' '\t']
let break = ['\n' '\r']
let nonbreak = [^ '\n' '\r']
let nzdigit = ['1'-'9']
let digit = (nzdigit | "0")
let hex   = (digit | ['A'-'F'])
let capital = ['A'-'Z']
let small = ['a'-'z']
let latin = (small | capital)
let item  = "*"+
let identifier = (small (digit | latin | "-")*)
let constructor = (capital (digit | latin | "-")*)
let symbol = ( [' '-'@'] | ['['-'`'] | ['{'-'~'] )
let opsymbol = ( '+' | '-' | '*' | '/' | '^' | '&' | '|' | '!' | ':' | '=' | '<' | '>' | '~' | '\'' | '.' | '?' )
let str = [^ ' ' '\t' '\n' '\r' '@' '`' '\\' '{' '}' '<' '>' '%' '|' '*' '$' '#' ';']
let mathsymbol = ( '+' | '-' | '*' | '/' | ':' | '=' | '<' | '>' | '~' | '\'' | '.' | ',' | '?' | '`' )

rule progexpr = parse
  | "%" {
      comment lexbuf;
      progexpr lexbuf
    }
  | ("@" (identifier as headertype) ":" (" "*) (nonbreak* as content) (break | eof)) {
      let pos = get_pos lexbuf in
      increment_line lexbuf;
      match headertype with
      | "require" -> HEADER_REQUIRE(pos, content)
      | "import"  -> HEADER_IMPORT(pos, content)
      | _         -> raise (LexError(pos, "undefined header type '" ^ headertype ^ "'"))
    }
  | space { progexpr lexbuf }
  | break {
      increment_line lexbuf;
      progexpr lexbuf
    }
  | "(" { push ProgramState; LPAREN(get_pos lexbuf) }
  | ")" {
      let pos = get_pos lexbuf in
      pop lexbuf "too many closing";
      RPAREN(pos)
    }
  | "(|" { push ProgramState; BRECORD(get_pos lexbuf) }
  | "|)" {
      let pos = get_pos lexbuf in
      pop lexbuf "too many closing";
      ERECORD(pos)
    }
  | "[" { push ProgramState; BLIST(get_pos lexbuf) }
  | "]" {
      let pos = get_pos lexbuf in
      pop lexbuf "too many closing";
      ELIST(pos)
     }
  | ";" { LISTPUNCT(get_pos lexbuf) }
  | "{" {
      push HorizontalState;
      ignore_space := true;
      BHORZGRP(get_pos lexbuf)
    }
  | "'<" {
      push VerticalState;
      BVERTGRP(get_pos lexbuf)
    }
  | "${" {
      push MathState;
      BMATHGRP(get_pos lexbuf)
    }
  | "<[" { BPATH(get_pos lexbuf) }
  | "]>" { EPATH(get_pos lexbuf) }
  | ".." { PATHCURVE(get_pos lexbuf) }
  | "--" { PATHLINE(get_pos lexbuf) }  (* -- prior to BINOP_MINUS -- *)
  | "`"+ {
      quote_range := get_pos lexbuf;
      quote_length := String.length (Lexing.lexeme lexbuf);
      literal_buffer |> Buffer.clear;
      literal lexbuf
    }
  | ("\\" (identifier | constructor)) {
      let tok = Lexing.lexeme lexbuf in HORZCMD(get_pos lexbuf, tok)
    }
  | ("+" (identifier | constructor)) {
      let tok = Lexing.lexeme lexbuf in VERTCMD(get_pos lexbuf, tok)
    }
  | "#"   { ACCESS(get_pos lexbuf) }
  | "->"  { ARROW(get_pos lexbuf) }
  | "<-"  { OVERWRITEEQ(get_pos lexbuf) }
  | "|"   { BAR(get_pos lexbuf) }
  | "_"   { WILDCARD(get_pos lexbuf) }
  | "."   { DOT(get_pos lexbuf) }
  | ":"   { COLON(get_pos lexbuf) }
  | ","   { COMMA(get_pos lexbuf) }
  | "::"  { CONS(get_pos lexbuf) }
  | "-"   { EXACT_MINUS(get_pos lexbuf) }
  | "="   { DEFEQ(get_pos lexbuf) }
  | "*"   { EXACT_TIMES(get_pos lexbuf) }

(* -- binary operators; should be extended -- *)
  | ("+" opsymbol*) { BINOP_PLUS(get_pos lexbuf, Lexing.lexeme lexbuf) }
  | ("-" opsymbol+) { BINOP_MINUS(get_pos lexbuf, Lexing.lexeme lexbuf) }
  | ("*" opsymbol+) { BINOP_TIMES(get_pos lexbuf, Lexing.lexeme lexbuf) }
  | ("/" opsymbol*) { BINOP_DIVIDES(get_pos lexbuf, Lexing.lexeme lexbuf) }
  | ("=" opsymbol+) { BINOP_EQ(get_pos lexbuf, Lexing.lexeme lexbuf) }
  | ("<" opsymbol*) { BINOP_LT(get_pos lexbuf, Lexing.lexeme lexbuf) }
  | (">" opsymbol*) { BINOP_GT(get_pos lexbuf, Lexing.lexeme lexbuf) }
  | ("&" opsymbol+) { BINOP_AMP(get_pos lexbuf, Lexing.lexeme lexbuf) }
  | ("|" opsymbol+) { BINOP_BAR(get_pos lexbuf, Lexing.lexeme lexbuf) }
  | ("^" opsymbol*) { BINOP_HAT(get_pos lexbuf, Lexing.lexeme lexbuf) }
  | "?"  { OPTIONALTYPE(get_pos lexbuf) }
  | "?:" { OPTIONAL(get_pos lexbuf) }
  | "?*" { OMISSION(get_pos lexbuf) }
  | "!" { DEREF(get_pos lexbuf) }
  | ("'" (identifier as xpltyvarnm)) { TYPEVAR(get_pos lexbuf, xpltyvarnm) }

  | ((constructor ".")+ identifier) {
        let tokstr = Lexing.lexeme lexbuf in
        let pos = get_pos lexbuf in
        let (mdlnmlst, varnm) = split_module_list tokstr in
          VARWITHMOD(pos, mdlnmlst, varnm)
      }

  | identifier {
        let tokstr = Lexing.lexeme lexbuf in
        let pos = get_pos lexbuf in
          match tokstr with
          | "not"               -> LNOT(pos)
          | "mod"               -> MOD(pos)
          | "if"                -> IF(pos)
          | "then"              -> THEN(pos)
          | "else"              -> ELSE(pos)
          | "let"               -> LETNONREC(pos)
          | "let-rec"           -> LETREC(pos)
          | "and"               -> LETAND(pos)
          | "in"                -> IN(pos)
          | "fun"               -> LAMBDA(pos)
          | "true"              -> TRUE(pos)
          | "false"             -> FALSE(pos)
          | "before"            -> BEFORE(pos)
          | "while"             -> WHILE(pos)
          | "do"                -> DO(pos)
          | "let-mutable"       -> LETMUTABLE(pos)
          | "match"             -> MATCH(pos)
          | "with"              -> WITH(pos)
          | "when"              -> WHEN(pos)
          | "as"                -> AS(pos)
          | "type"              -> TYPE(pos)
          | "of"                -> OF(pos)
          | "module"            -> MODULE(pos)
          | "struct"            -> STRUCT(pos)
          | "sig"               -> SIG(pos)
          | "val"               -> VAL(pos)
          | "end"               -> END(pos)
          | "direct"            -> DIRECT(pos)
          | "constraint"        -> CONSTRAINT(pos)
          | "let-inline"        -> LETHORZ(pos)
          | "let-block"         -> LETVERT(pos)
          | "let-math"          -> LETMATH(pos)
          | "controls"          -> CONTROLS(pos)
          | "cycle"             -> CYCLE(pos)
          | "inline-cmd"        -> HORZCMDTYPE(pos)
          | "block-cmd"         -> VERTCMDTYPE(pos)
          | "math-cmd"          -> MATHCMDTYPE(pos)
          | "command"           -> COMMAND(pos)
          | _                   -> VAR(pos, tokstr)
      }
  | constructor { CONSTRUCTOR(get_pos lexbuf, Lexing.lexeme lexbuf) }
  | (digit | (nzdigit digit+))                            { INTCONST(get_pos lexbuf, int_of_string (Lexing.lexeme lexbuf)) }
  | (("0x" | "0X") hex+)                                  { INTCONST(get_pos lexbuf, int_of_string (Lexing.lexeme lexbuf)) }
  | ((digit+ "." digit*) | ("." digit+))                  { FLOATCONST(get_pos lexbuf, float_of_string (Lexing.lexeme lexbuf)) }
  | (((digit | (nzdigit digit+)) as i) (identifier as unitnm))  { LENGTHCONST(get_pos lexbuf, float_of_int (int_of_string i), unitnm) }
  | (((digit+ "." digit*) as flt) (identifier as unitnm))       { LENGTHCONST(get_pos lexbuf, float_of_string flt, unitnm) }
  | ((("." digit+) as flt) (identifier as unitnm))              { LENGTHCONST(get_pos lexbuf, float_of_string flt, unitnm) }
  | eof {
      if Stack.length stack = 1 then EOI else
        report_error lexbuf "text input ended while reading a program area"
    }
  | _ as c { report_error lexbuf ("illegal token '" ^ (String.make 1 c) ^ "' in a program area") }


and vertexpr = parse
  | "%" {
      comment lexbuf;
      vertexpr lexbuf
    }
  | (break | space)* {
      increment_line_for_each_break lexbuf (Lexing.lexeme lexbuf);
      vertexpr lexbuf
    }
  | ("#" (identifier as varnm)) {
      push ActiveState;
      VARINVERT(get_pos lexbuf, [], varnm)
    }
  | ("#" (constructor ".")* (identifier | constructor)) {
      let csnmpure = Lexing.lexeme lexbuf in
      let csstr = String.sub csnmpure 1 ((String.length csnmpure) - 1) in
      let (mdlnmlst, csnm) = split_module_list csstr in
        push ActiveState;
        VARINVERT(get_pos lexbuf, mdlnmlst, csnm)
    }
  | ("+" (identifier | constructor)) {
      push ActiveState;
      VERTCMD(get_pos lexbuf, Lexing.lexeme lexbuf)
    }
  | ("+" (constructor ".")* (identifier | constructor)) {
      let tokstrpure = Lexing.lexeme lexbuf in
      let tokstr = String.sub tokstrpure 1 ((String.length tokstrpure) - 1) in
      let (mdlnmlst, csnm) = split_module_list tokstr in
      push ActiveState;
      VERTCMDWITHMOD(get_pos lexbuf, mdlnmlst, "+" ^ csnm)
    }
  | "<" { push VerticalState; BVERTGRP(get_pos lexbuf) }
  | ">" {
      let pos = get_pos lexbuf in
      pop lexbuf "too many closing";
      ignore_space := false;
      EVERTGRP(pos)
    }
  | "{" {
      push HorizontalState;
      ignore_space := true;
      BHORZGRP(get_pos lexbuf)
    }
  | eof {
      if Stack.length stack = 1 then EOI else
        report_error lexbuf "unexpected end of input while reading a vertical area"
    }
  | _ as c {
      report_error lexbuf ("unexpected character '" ^ (String.make 1 c) ^ "' in a vertical area")
    }

and horzexpr = parse
  | "%" {
      ignore_space := true;
      comment lexbuf;
      horzexpr lexbuf
    }
  | ((break | space)* "{") {
      increment_line_for_each_break lexbuf (Lexing.lexeme lexbuf);
      push HorizontalState;
      ignore_space := true;
      BHORZGRP(get_pos lexbuf)
    }
  | ((break | space)* "}") {
      increment_line_for_each_break lexbuf (Lexing.lexeme lexbuf);
      let pos = get_pos lexbuf in
      pop lexbuf "too many closing";
      ignore_space := false;
      EHORZGRP(pos)
    }
  | ((break | space)* "<") {
      increment_line_for_each_break lexbuf (Lexing.lexeme lexbuf);
      push VerticalState;
      BVERTGRP(get_pos lexbuf)
    }
  | ((break | space)* "|") {
      increment_line_for_each_break lexbuf (Lexing.lexeme lexbuf);
      ignore_space := true;
      SEP(get_pos lexbuf)
    }
  | break {
      increment_line lexbuf;
      if !ignore_space then horzexpr lexbuf else
        begin ignore_space := true; BREAK(get_pos lexbuf) end
    }
  | space {
      if !ignore_space then horzexpr lexbuf else
        begin ignore_space := true; SPACE(get_pos lexbuf) end
    }
  | ((break | space)* (item as itemstr)) {
      increment_line_for_each_break lexbuf (Lexing.lexeme lexbuf);
      ignore_space := true;
      ITEM(get_pos lexbuf, String.length itemstr)
    }
  | ("#" (identifier as varnm)) {
      push ActiveState;
      VARINHORZ(get_pos lexbuf, [], varnm)
    }
  | ("#" (constructor ".")* (identifier | constructor)) {
      let csnmpure = Lexing.lexeme lexbuf in
      let csstr = String.sub csnmpure 1 ((String.length csnmpure) - 1) in
      let (mdlnmlst, csnm) = split_module_list csstr in
        push ActiveState;
        VARINHORZ(get_pos lexbuf, mdlnmlst, csnm)
    }
  | ("\\" (identifier | constructor)) {
      let tok = Lexing.lexeme lexbuf in
      let rng = get_pos lexbuf in
      push ActiveState;
      HORZCMD(rng, tok)
    }
  | ("\\" (constructor ".")* (identifier | constructor)) {
      let tokstrpure = Lexing.lexeme lexbuf in
      let tokstr = String.sub tokstrpure 1 ((String.length tokstrpure) - 1) in
      let (mdlnmlst, csnm) = split_module_list tokstr in
      let rng = get_pos lexbuf in
        push ActiveState;
        HORZCMDWITHMOD(rng, mdlnmlst, "\\" ^ csnm)
    }
  | ("\\" symbol) {
      let tok = String.sub (Lexing.lexeme lexbuf) 1 1 in
        begin
          ignore_space := false;
          CHAR(get_pos lexbuf, tok)
        end
    }
  | ((break | space)* ("`"+ as openqtstr)) {
      increment_line_for_each_break lexbuf (Lexing.lexeme lexbuf);
      quote_range := get_pos lexbuf;
      quote_length := String.length openqtstr;
      literal_buffer |> Buffer.clear;
      literal lexbuf
    }
  | "${" {
      push MathState;
      BMATHGRP(get_pos lexbuf)
    }
  | eof {
      if Stack.length stack = 1 then EOI else
        report_error lexbuf "unexpected end of input while reading an inline text area"
    }
  | str+ {
      ignore_space := false;
      let tok = Lexing.lexeme lexbuf in CHAR(get_pos lexbuf, tok)
    }

  | _ as c { report_error lexbuf ("illegal token '" ^ (String.make 1 c) ^ "' in an inline text area") }

and mathexpr = parse
  | space { mathexpr lexbuf }
  | break { increment_line lexbuf; mathexpr lexbuf }
  | "%" {
      comment lexbuf;
      mathexpr lexbuf
    }
  | "!{" {
      push HorizontalState;
      ignore_space := true;
      BHORZGRP(get_pos lexbuf);
    }
  | "!<" {
      push VerticalState;
      BVERTGRP(get_pos lexbuf)
    }
  | "!(" {
      push ProgramState;
      LPAREN(get_pos lexbuf)
    }
  | "![" {
      push ProgramState;
      BLIST(get_pos lexbuf)
    }
  | "!(|" {
      push ProgramState;
      BRECORD(get_pos lexbuf)
    }
  | "{" {
      push MathState;
      BMATHGRP(get_pos lexbuf)
    }
  | "}" {
      let pos = get_pos lexbuf in
      pop lexbuf "too many closing";
      ignore_space := false;
      EMATHGRP(pos)
    }
  | "^" { SUPERSCRIPT(get_pos lexbuf) }
  | "_" { SUBSCRIPT(get_pos lexbuf) }
  | mathsymbol+     { MATHCHAR(get_pos lexbuf, Lexing.lexeme lexbuf) }
  | (latin | digit) { MATHCHAR(get_pos lexbuf, Lexing.lexeme lexbuf) }
  | ("#" (identifier as varnm)) {
      VARINMATH(get_pos lexbuf, [], varnm)
    }
  | ("#" (constructor ".")* (identifier | constructor)) {
      let csnmpure = Lexing.lexeme lexbuf in
      let csstr = String.sub csnmpure 1 ((String.length csnmpure) - 1) in
      let (mdlnmlst, csnm) = split_module_list csstr in
        VARINMATH(get_pos lexbuf, mdlnmlst, csnm)
    }
  | ("\\" (identifier | constructor)) {
      let csnm = Lexing.lexeme lexbuf in
        MATHCMD(get_pos lexbuf, csnm)
    }
  | ("\\" (constructor ".")* (identifier | constructor)) {
      let csnmpure = Lexing.lexeme lexbuf in
      let csstr = String.sub csnmpure 1 ((String.length csnmpure) - 1) in
      let (mdlnmlst, csnm) = split_module_list csstr in
        MATHCMDWITHMOD(get_pos lexbuf, mdlnmlst, "\\" ^ csnm)
    }
  | ("\\" symbol) {
      let tok = String.sub (Lexing.lexeme lexbuf) 1 1 in
        MATHCHAR(get_pos lexbuf, tok)
    }
  | _ as c { report_error lexbuf ("illegal token '" ^ (String.make 1 c) ^ "' in a math area") }

  | eof { report_error lexbuf "unexpected end of file in a math area" }

and active = parse
  | "%" {
      comment lexbuf;
      active lexbuf
    }
  | space { active lexbuf }
  | break { increment_line lexbuf; active lexbuf }
  | "?:" { OPTIONAL(get_pos lexbuf) }
  | "?*" { OMISSION(get_pos lexbuf) }
  | "(" {
      push ProgramState;
      LPAREN(get_pos lexbuf)
    }
  | "(|" {
      push ProgramState;
      BRECORD(get_pos lexbuf)
    }
  | "[" {
      push ProgramState;
      BLIST(get_pos lexbuf)
    }
  | "{" {
      let pos = get_pos lexbuf in
      pop lexbuf "BUG; this cannot happen";
      push HorizontalState;
      ignore_space := true;
      BHORZGRP(pos)
    }
  | "<" {
      let pos = get_pos lexbuf in
      pop lexbuf "BUG; this cannot happen";
      push VerticalState;
      BVERTGRP(pos)
    }
  | ";" {
      let pos = get_pos lexbuf in
      pop lexbuf "BUG; this cannot happen";
      ignore_space := false;
      ENDACTIVE(pos)
    }
  | eof {
      report_error lexbuf "unexpected end of input while reading an active area"
    }
  | _ {
      let tok = Lexing.lexeme lexbuf in
      report_error lexbuf ("unexpected token '" ^ tok ^ "' in an active area")
    }

and literal = parse
  | "`"+ {
      let tok = Lexing.lexeme lexbuf in
      let len = String.length tok in
        if len < !quote_length then begin
          Buffer.add_string literal_buffer tok;
          literal lexbuf
        end else if len > !quote_length then
          report_error lexbuf "literal area was closed with too many '`'s"
        else
          let pos = Range.unite !quote_range (get_pos lexbuf) in
          LITERAL(pos, Buffer.contents literal_buffer)
    }
  | break {
      let tok = Lexing.lexeme lexbuf in
      increment_line lexbuf;
      Buffer.add_string literal_buffer tok;
      literal lexbuf
    }
  | eof {
      report_error lexbuf "unexpected end of input while reading literal area"
    }
  | _ {
      let tok = Lexing.lexeme lexbuf in
      Buffer.add_string literal_buffer tok;
      literal lexbuf
    }

and comment = parse
  | break {
      increment_line lexbuf;
    }
  | eof { () }
  | _ { comment lexbuf }

{
  let rec cut_token lexbuf =
    match next_state () with
    | ProgramState    -> progexpr lexbuf
    | VerticalState   -> vertexpr lexbuf
    | HorizontalState -> horzexpr lexbuf
    | ActiveState     -> active lexbuf
    | MathState       -> mathexpr lexbuf

}
