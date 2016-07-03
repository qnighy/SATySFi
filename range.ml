
type t = Dummy of string | Normal of int * int * int * int


let dummy msg = Dummy(msg)


let to_string rng =
  let s = string_of_int in
    match rng with
    | Dummy(msg)                   -> "dummy range '" ^ msg ^ "'"
    | Normal(ln1, pos1, ln2, pos2) ->
        if ln1 = ln2 then
          "line " ^ (s ln1) ^ ", characters " ^ (s pos1) ^ "-" ^ (s pos2)
        else
          "line " ^ (s ln1) ^ ", character " ^ (s pos1) ^ " to line " ^ (s ln2) ^ ", character " ^ (s pos2)


let unite rng1 rng2 =
  match (rng1, rng2) with
  | (Normal(ln1, pos1, _, _), Normal(_, _, ln2, pos2)) -> Normal(ln1, pos1, ln2, pos2)
  | _                                                  -> Dummy("dummy")


let make ln pos1 pos2 = Normal(ln, pos1, ln, pos2)
