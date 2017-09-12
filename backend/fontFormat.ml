
let print_for_debug msg = print_endline msg  (* for debug *)


type file_path = string

type glyph_id = Otfm.glyph_id


let gid x = x  (* for debug *)


let hex_of_glyph_id gid =
  let b0 = gid / 256 in
  let b1 = gid mod 256 in
    Printf.sprintf "%02X%02X" b0 b1


exception FailToLoadFontFormatOwingToSize   of file_path
exception FailToLoadFontFormatOwingToSystem of string
exception FontFormatBroken                  of Otfm.error
exception FontFormatBrokenAboutWidthClass
exception NoGlyphID                         of Otfm.glyph_id


let string_of_file (flnmin : file_path) : string =
  try
    let bufsize = 65536 in  (* temporary; size of buffer for loading font format file *)
    let buf : Buffer.t = Buffer.create bufsize in
    let byt : bytes = Bytes.create bufsize in
    let ic : in_channel = open_in_bin flnmin in
      try
        begin
          while true do
            let c = input ic byt 0 bufsize in
              if c = 0 then raise Exit else
                Buffer.add_substring buf (Bytes.unsafe_to_string byt) 0 c
          done ;
          assert false
        end
      with
      | Exit           -> begin close_in ic ; Buffer.contents buf end
      | Failure(_)     -> begin close_in ic ; raise (FailToLoadFontFormatOwingToSize(flnmin)) end
      | Sys_error(msg) -> begin close_in ic ; raise (FailToLoadFontFormatOwingToSystem(msg)) end
  with
  | Sys_error(msg) -> raise (FailToLoadFontFormatOwingToSystem(msg))


let get_main_decoder (src : file_path) : Otfm.decoder =
  let s = string_of_file src in
  let d = Otfm.decoder (`String(s)) in
    d


module GlyphIDTable
: sig
    type t
    val create : int -> t
    val add : Uchar.t -> glyph_id -> t -> unit
    val find_opt : Uchar.t -> t -> glyph_id option
  end
= struct
    module Ht = Hashtbl.Make
      (struct
        type t = Uchar.t
        let equal = (=)
        let hash = Hashtbl.hash
      end)

    type t = glyph_id Ht.t

    let create = Ht.create

    let add uch gid gidtbl = Ht.add gidtbl uch gid

    let find_opt uch gidtbl =
      try Some(Ht.find gidtbl uch) with
      | Not_found -> None
  end


module GlyphMetricsTable
: sig
    type t
    val create : int -> t
    val add : glyph_id -> int * int * int -> t -> unit
    val find_opt : glyph_id -> t -> (int * int * int) option
(*
    val to_width_list : t -> (glyph_id * int) list
*)
    val fold : (glyph_id -> int * int * int -> 'a -> 'a) -> 'a -> t -> 'a
  end
= struct
    module Ht = Hashtbl.Make
      (struct
        type t = glyph_id
        let equal = (=)
        let hash = Hashtbl.hash
      end)

    type t = (int * int * int) Ht.t

    let create = Ht.create

    let add gid (w, h, d) gmtbl = Ht.add gmtbl gid (w, h, d)

    let find_opt gid gmtbl =
      try Some(Ht.find gmtbl gid) with
      | Not_found -> None

    let fold f init gmtbl =
      Ht.fold f gmtbl init
(*
    let to_width_list gmtbl =
      Ht.fold (fun gid (w, _, _) acc -> (gid, w) :: acc) gmtbl []
*)
  end


type ligature_matching =
  | MatchExactly of glyph_id * glyph_id list
  | NoMatch


module LigatureTable
: sig
    type t
    val create : int -> t
    val add : glyph_id -> (glyph_id list * glyph_id) list -> t -> unit
    val match_prefix : glyph_id list -> t -> ligature_matching
  end
= struct
    module Ht = Hashtbl.Make
      (struct
        type t = glyph_id
        let equal = (=)
        let hash = Hashtbl.hash
      end)

    type t = ((glyph_id list * glyph_id) list) Ht.t

    let create = Ht.create

    let add gid liginfolst ligtbl = Ht.add ligtbl gid liginfolst

    let rec prefix lst1 lst2 =
      match (lst1, lst2) with
      | ([], _)                                              -> Some(lst2)
      | (head1 :: tail1, head2 :: tail2)  when head1 = head2 -> prefix tail1 tail2
      | _                                                    -> None

    let rec lookup liginfolst gidlst =
      match liginfolst with
      | []                               -> NoMatch
      | (gidtail, gidlig) :: liginfotail ->
          match prefix gidtail gidlst with
          | None          -> lookup liginfotail gidlst
          | Some(gidrest) -> MatchExactly(gidlig, gidrest)

    let match_prefix gidlst ligtbl =
      match gidlst with
      | []                -> NoMatch
      | gidfst :: gidtail ->
          try
            let liginfolst = Ht.find ligtbl gidfst in
            lookup liginfolst gidtail
          with
          | Not_found -> NoMatch
end


let get_ligature_table (d : Otfm.decoder) : LigatureTable.t =
  let ligtbl = LigatureTable.create 32 (* temporary; size of the hash table *) in
  let res =
    () |> Otfm.gsub d "latn" None "liga" (* temporary; should depend on script and language *)
      (fun () (gid, liginfolst) ->
        ligtbl |> LigatureTable.add gid liginfolst
      )
  in
  match res with
  | Ok(())   -> ligtbl
  | Error(e) ->
      match e with
      | `Missing_required_table(tag)
          when tag = Otfm.Tag.gsub -> ligtbl
      | _ ->
          let () = Format.printf "@[%a@]" Otfm.pp_error e in  (* for debug *)
          raise (FontFormatBroken(e))


module KerningTable
: sig
    type t
    val create : int -> t
    val add : glyph_id -> glyph_id -> int -> t -> unit
    val add_by_class : Otfm.class_definition list -> Otfm.class_definition list -> (Otfm.class_value * (Otfm.class_value * Otfm.value_record * Otfm.value_record) list) list -> t -> unit
    val find_opt : glyph_id -> glyph_id -> t -> int option
  end
= struct
    module HtSingle = Hashtbl.Make
      (struct
        type t = Otfm.glyph_id * Otfm.glyph_id
        let equal = (=)
        let hash = Hashtbl.hash
      end)

    module HtClass = Hashtbl.Make
      (struct
        type t = Otfm.class_value * Otfm.class_value
        let equal = (=)
        let hash = Hashtbl.hash
      end)

    type subtable = Otfm.class_definition list * Otfm.class_definition list * int HtClass.t

    type t = int HtSingle.t * (subtable list) ref

    let create size =
      let htS = HtSingle.create size in
      let htC = ref [] in
        (htS, htC)

    let add gid1 gid2 wid (htS, _) =
      begin HtSingle.add htS (gid1, gid2) wid; end

    let add_by_class clsdeflst1 clsdeflst2 lst (_, refC) =
      let htC = HtClass.create 1024 (* temporary *) in
      begin
        lst |> List.iter (fun (cls1, pairposlst) ->
          pairposlst |> List.iter (fun (cls2, valrcd1, valrcd2) ->
            match valrcd1.Otfm.x_advance with
            | None      -> ()
            | Some(0)   -> ()
            | Some(xa1) -> HtClass.add htC (cls1, cls2) xa1
          )
        );
        refC := (clsdeflst1, clsdeflst2, htC) :: !refC;
      end

    let rec to_class_value gid clsdeflst =
      let iter = to_class_value gid in
        match clsdeflst with
        | []                                        -> None
        | Otfm.GlyphToClass(g, c) :: tail           -> if g = gid then Some(c) else iter tail
        | Otfm.GlyphRangeToClass(gs, ge, c) :: tail -> if gs <= gid && gid <= ge then Some(c) else iter tail
      

    let find_opt gid1 gid2 ((htS, refC) : t) =

      let rec find_for_subtables subtbllst =
        match subtbllst with
        | []                        -> None
        | (cdl1, cdl2, htC) :: tail ->
            match (to_class_value gid1 cdl1, to_class_value gid2 cdl2) with
            | (Some(cls1), Some(cls2)) ->
                begin
                  try Some(HtClass.find htC (cls1, cls2)) with
                  | Not_found -> find_for_subtables tail
                end
            | _ -> find_for_subtables tail
      in

      try Some(HtSingle.find htS (gid1, gid2)) with
      | Not_found -> find_for_subtables (!refC)
  end


let get_kerning_table (d : Otfm.decoder) =
  let kerntbl = KerningTable.create 32 (* temporary; size of the hash table *) in
  begin
    () |> Otfm.kern d (fun () kinfo ->
      match kinfo with
      | { Otfm.kern_dir = `H; Otfm.kern_kind = `Kern; Otfm.kern_cross_stream = false } -> (`Fold, ())
      | _                                                                              -> (`Skip, ())
    ) (fun () gid1 gid2 wid ->
      kerntbl |> KerningTable.add gid1 gid2 wid
    )
  end |>
  (function  (* for debug *)
    | Ok(())   -> print_for_debug "'kern' exists"   (* for debug *)
    | Error(e) -> print_for_debug "'kern' missing"  (* for debug *)
  ) |>  (* for debug *)
  ignore ;
      match
        () |> Otfm.gpos d "latn" None "kern"  (* temporary; script and language system should be variable *)
          (fun () (gid1, pairposlst) ->
            pairposlst |> List.iter (fun (gid2, valrcd1, valrcd2) ->
              match valrcd1.Otfm.x_advance with
              | None      -> ()
              | Some(xa1) ->
                  let () = if gid1 <= 100 then print_for_debug (Printf.sprintf "Add KERN (%d, %d) xa1 = %d" gid1 gid2 xa1) in  (* for debug *)
                  kerntbl |> KerningTable.add gid1 gid2 xa1
            )
          )
          (fun clsdeflst1 clsdeflst2 () sublst ->
            kerntbl |> KerningTable.add_by_class clsdeflst1 clsdeflst2 sublst;
          )
      with
      | Ok(sublst) ->
          let () = print_for_debug "'GPOS' exists" in  (* for debug *)
            kerntbl

      | Error(e) ->
          match e with
          | `Missing_required_table(t)
              when t = Otfm.Tag.gpos ->
                let () = print_for_debug "'GPOS' missing" in  (* for debug *)
                kerntbl
          | _                        -> raise (FontFormatBroken(e))


type decoder = {
  main                : Otfm.decoder;
  glyph_id_table      : GlyphIDTable.t;
  glyph_metrics_table : GlyphMetricsTable.t;
  kerning_table       : KerningTable.t;
  ligature_table      : LigatureTable.t;
  default_ascent      : int;
  default_descent     : int;
}

type 'a resource =
  | Data           of 'a
  | EmbeddedStream of int

type predefined_encoding =
  | StandardEncoding
  | MacRomanEncoding
  | WinAnsiEncoding

type differences = (string * int) list

type encoding =
  | ImplicitEncoding
  | PredefinedEncoding of predefined_encoding
  | CustomEncoding     of predefined_encoding * differences

type cmap_resource = (string resource) ref  (* temporary;*)

type cmap =
  | PredefinedCMap of string
  | CMapFile       of cmap_resource

type cid_system_info = {
    registry   : string;
    ordering   : string;
    supplement : int;
  }

type bbox = int * int * int * int

type matrix = float * float * float * float

type font_stretch =
  | UltraCondensedStretch | ExtraCondensedStretch | CondensedStretch | SemiCondensedStetch
  | NormalStretch
  | SemiExpandedStretch | ExpandedStretch | ExtraExpandedStretch | UltraExpandedStretch


let font_stretch_of_width_class = function
  | 0 -> UltraCondensedStretch
  | 1 -> ExtraCondensedStretch
  | 3 -> CondensedStretch
  | 4 -> SemiCondensedStetch
  | 5 -> NormalStretch
  | 6 -> SemiExpandedStretch
  | 7 -> ExpandedStretch
  | 8 -> ExtraExpandedStretch
  | 9 -> UltraExpandedStretch
  | _ -> raise FontFormatBrokenAboutWidthClass


type font_descriptor = {
    font_name    : string;
    font_family  : string;
    font_stretch : font_stretch option;
    font_weight  : int option;  (* -- ranges only over {100, 200, ..., 900} -- *)
    flags        : int option;  (* temporary; maybe should be handled as a boolean record *)
    font_bbox    : bbox;
    italic_angle : float;
    ascent       : int;
    descent      : int;
    stemv        : float;
    font_data    : (Otfm.decoder resource) ref;
    (* temporary; should contain more fields *)
  }


let to_base85_pdf_bytes (d : Otfm.decoder) : Pdfio.bytes =
  match Otfm.decoder_src d with
  | `String(s) ->
      let s85 = Base85.encode s in
        Pdfio.bytes_of_string s85


let add_stream_of_decoder (pdf : Pdf.t) (d : Otfm.decoder) (subtypeopt : string option) () : int =
  let bt85 = to_base85_pdf_bytes d in
  let len = Pdfio.bytes_size bt85 in
  let contents = [
      ("/Length", Pdf.Integer(len));
      ("/Filter", Pdf.Name("/ASCII85Decode"));
    ]
  in
  let dict =
    match subtypeopt with
    | None          -> contents
    | Some(subtype) -> ("/Subtype", Pdf.Name("/" ^ subtype)) :: contents
  in
  let objstream = Pdf.Stream(ref (Pdf.Dictionary(dict), Pdf.Got(bt85))) in
  let irstream = Pdf.addobj pdf objstream in
    irstream


let get_glyph_id_main (d : Otfm.decoder) (uch : Uchar.t) : Otfm.glyph_id option =
  let cp = Uchar.to_int uch in
  let cmapres =
    Otfm.cmap d (fun accopt mapkd (u0, u1) gid ->
      match accopt with
      | Some(_) -> accopt
      | None    -> if u0 <= cp && cp <= u1 then Some(gid + (cp - u0)) else None
    ) None
  in
    match cmapres with
    | Error(e)                   -> raise (FontFormatBroken(e))
    | Ok(((_, _, _), None))      -> None
    | Ok(((_, _, _), Some(gid))) -> Some(gid)


(* PUBLIC *)
let get_glyph_id (dcdr : decoder) (uch : Uchar.t) : glyph_id option =
  let gidtbl = dcdr.glyph_id_table in
    match gidtbl |> GlyphIDTable.find_opt uch with
    | Some(gid) -> Some(gid)
    | None      ->
        match get_glyph_id_main dcdr.main uch with
        | None      -> None
        | Some(gid) ->
            begin
              gidtbl |> GlyphIDTable.add uch gid;
(*              print_for_debug (Printf.sprintf "'%c' -> %d" (Uchar.to_char uch) gid) ;  (* for debug *) *)
              Some(gid)
            end


let get_glyph_raw_contour_list_and_bounding_box (dcdr : decoder) gid
    : ((((bool * int * int) list) list * (int * int * int * int)) option, Otfm.error) result =
  let d = dcdr.main in
  match Otfm.loca d gid with
  | Error(e)    -> Error(e)
  | Ok(None)    -> Ok(None)
  | Ok(Some(gloc)) ->
      match Otfm.glyf d gloc with
      | Error(e)                        -> Error(e)
      | Ok((`Composite(_), _))          -> Ok(None)
          (* temporary; does not deal with composite glyphs *)
      | Ok((`Simple(precntrlst), bbox)) -> Ok(Some((precntrlst, bbox)))


let get_glyph_height_and_depth (dcdr : decoder) (gid : glyph_id) =
  match get_glyph_raw_contour_list_and_bounding_box dcdr gid with
  | Error(`Missing_required_table(t))
               when t = Otfm.Tag.loca -> (dcdr.default_ascent, dcdr.default_descent)
  | Error(e)                          -> raise (FontFormatBroken(e))
  | Ok(None)                          -> (dcdr.default_ascent, dcdr.default_descent)
  | Ok(Some((_, (_, ymin, _, ymax)))) -> (ymax, ymin)


let get_glyph_advance_width (dcdr : decoder) (gidkey : glyph_id) : int =
  let d = dcdr.main in
  let hmtxres =
    None |> Otfm.hmtx d (fun accopt gid adv lsb ->
      match accopt with
      | Some(_) -> accopt
      | None    -> if gid = gidkey then Some((adv, lsb)) else None
    )
  in
    match hmtxres with
    | Error(e)             -> raise (FontFormatBroken(e))
    | Ok(None)             -> 0
    | Ok(Some((adv, lsb))) -> adv


let get_glyph_metrics_main (dcdr : decoder) (gid : glyph_id) =
  let wid = get_glyph_advance_width dcdr gid in
  let (hgt, dpt) = get_glyph_height_and_depth dcdr gid in
    (wid, hgt, dpt)


(* PUBLIC *)
let get_glyph_metrics (dcdr : decoder) (gid : glyph_id) : int * int * int =
  let gmtbl = dcdr.glyph_metrics_table in
    match gmtbl |> GlyphMetricsTable.find_opt gid with
    | Some(gm) -> gm
    | None     ->
        let gm = get_glyph_metrics_main dcdr gid in
          begin gmtbl |> GlyphMetricsTable.add gid gm ; gm end



let get_truetype_widths_list (dcdr : decoder) (firstchar : int) (lastchar : int) : int list =
  let d = dcdr.main in
  let rec range acc m n =
    if m > n then List.rev acc else
      range (m :: acc) (m + 1) n
  in
    (range [] firstchar lastchar) |> List.map (fun charcode ->
      get_glyph_id_main d (Uchar.of_int charcode) |> function
        | None      -> 0
        | Some(gid) -> get_glyph_advance_width dcdr gid
    )


let font_descriptor_of_decoder d font_name =
  let (>>-) x f =
    match x with
    | Error(e) -> raise (FontFormatBroken(e))
    | Ok(v)    -> f v
  in
    Otfm.head d >>- fun rcdhead ->
    Otfm.hhea d >>- fun rcdhhea ->
    Otfm.os2 d  >>- fun rcdos2 ->
    {
      font_name    = font_name; (* -- same as Otfm.postscript_name dcdr -- *)
      font_family  = "";    (* temporary; should be gotten from decoder *)
      font_stretch = Some(font_stretch_of_width_class rcdos2.Otfm.os2_us_width_class);
      font_weight  = Some(rcdos2.Otfm.os2_us_weight_class);
      flags        = None;  (* temporary; should be gotten from decoder *)
      font_bbox    = (rcdhead.Otfm.head_xmin, rcdhead.Otfm.head_ymin,
                      rcdhead.Otfm.head_xmax, rcdhead.Otfm.head_ymax);
      italic_angle = 0.;    (* temporary; should be gotten from decoder; 'post.italicAngle' *)
      ascent       = rcdhhea.Otfm.hhea_ascender;
      descent      = rcdhhea.Otfm.hhea_descender;
      stemv        = 0.;    (* temporary; should be gotten from decoder *)
      font_data    = ref (Data(d));
      (* temporary; should contain more fields *)
    }


let get_postscript_name dcdr =
  match Otfm.postscript_name dcdr with
  | Error(e)    -> raise (FontFormatBroken(e))
  | Ok(None)    -> assert false  (* temporary *)
  | Ok(Some(x)) -> x


type embedding =
  | FontFile
  | FontFile2
  | FontFile3 of string


module Type1Scheme_
= struct
    type font = {
        name            : string option;
          (* --
               obsolete field; required in PDF 1.0
               but optional in all other versions
             -- *)
        base_font       : string;
        first_char      : int;
        last_char       : int;
        widths          : int list;
        font_descriptor : font_descriptor;
        encoding        : encoding;
        to_unicode      : cmap_resource option;
      }


    let of_decoder dcdr fc lc =
      let d = dcdr.main in
      let base_font = get_postscript_name d in
        {
          name            = None;
          base_font       = base_font;
          first_char      = fc;
          last_char       = lc;
          widths          = get_truetype_widths_list dcdr fc lc;
          font_descriptor = font_descriptor_of_decoder d base_font;
          encoding        = PredefinedEncoding(StandardEncoding);
          to_unicode      = None;
        }


    let to_pdfdict_scheme fontsubtype embedding pdf trtyfont dcdr =
      let d = dcdr.main in
      let (font_file_key, embedsubtypeopt) =
        match embedding with
        | FontFile       -> ("/FontFile", None)
        | FontFile2      -> ("/FontFile2", None)
        | FontFile3(sub) -> ("/FontFile3", Some(sub))
      in
      let fontname  = trtyfont.base_font in
      let firstchar = trtyfont.first_char in
      let lastchar  = trtyfont.last_char in
      let widths    = trtyfont.widths in
      let fontdescr = trtyfont.font_descriptor in
      let irstream = add_stream_of_decoder pdf d embedsubtypeopt () in
        (* -- add to the PDF the stream in which the font file is embedded -- *)
      let objdescr =
        Pdf.Dictionary[
          ("/Type"       , Pdf.Name("/FontDescriptor"));
          ("/FontName"   , Pdf.Name("/" ^ fontname));
          ("/Flags"      , Pdf.Integer(4));  (* temporary; should be variable *)
          ("/FontBBox"   , Pdf.Array[Pdf.Integer(0); Pdf.Integer(0); Pdf.Integer(0); Pdf.Integer(0)]);  (* temporary; should be variable *)
          ("/ItalicAngle", Pdf.Real(fontdescr.italic_angle));
          ("/Ascent"     , Pdf.Integer(fontdescr.ascent));
          ("/Descent"    , Pdf.Integer(fontdescr.descent));
          ("/StemV"      , Pdf.Real(fontdescr.stemv));
          (font_file_key , Pdf.Indirect(irstream));
        ]
      in
      let irdescr = Pdf.addobj pdf objdescr in
        Pdf.Dictionary[
          ("/Type"          , Pdf.Name("/Font"));
          ("/Subtype"       , Pdf.Name("/" ^ fontsubtype));
          ("/BaseFont"      , Pdf.Name("/" ^ fontname));
          ("/FirstChar"     , Pdf.Integer(firstchar));
          ("/LastChar"      , Pdf.Integer(lastchar));
          ("/Widths"        , Pdf.Array(List.map (fun x -> Pdf.Integer(x)) widths));
          ("/FontDescriptor", Pdf.Indirect(irdescr));
        ]
end

module Type1
= struct
    include Type1Scheme_

    let to_pdfdict = to_pdfdict_scheme "Type1" (FontFile3("Type1C"))
  end

module TrueType
= struct
    include Type1Scheme_

    let to_pdfdict = to_pdfdict_scheme "TrueType" FontFile2
  end

module Type3
= struct
    type font = {
        name            : string;
        font_bbox       : bbox;
        font_matrix     : matrix;
        encoding        : encoding;
        first_char      : int;
        last_char       : int;
        widths          : int list;
        font_descriptor : font_descriptor;
        to_unicode      : cmap_resource option;
      }
  end


module CIDFontType0
= struct
    type font = {
        cid_system_info : cid_system_info;
        base_font       : string;
        font_descriptor : font_descriptor;
        dw              : int option;
        dw2             : (int * int) option;
        (* temporary; should contain more fields; /W2 *)
        (* --
             Doesn't have to contain information about /W entry;
             the PDF file will be furnished with /W entry when outputted
             according to the glyph metrics table
           -- *)
      }

    let of_decoder dcdr widlst cidsysinfo =
      let d = dcdr.main in
      let base_font = get_postscript_name d in
        {
          cid_system_info = cidsysinfo;
          base_font       = base_font;
          font_descriptor = font_descriptor_of_decoder d base_font;
          dw              = None;  (* temporary *)
          dw2             = None;  (* temporary *)
        }
  end

type cid_to_gid_map =
  | CIDToGIDIdentity
  | CIDToGIDStream   of (string resource) ref  (* temporary *)

module CIDFontType2
= struct
    type font = {
        cid_system_info : cid_system_info;
        base_font       : string;
        font_descriptor : font_descriptor;
        dw              : int option;
        dw2             : (int * int) option;
        cid_to_gid_map  : cid_to_gid_map;
        (* temporary; should contain more fields; /W, /W2 *)
      }
  end

type cid_font =
  | CIDFontType0 of CIDFontType0.font
  | CIDFontType2 of CIDFontType2.font


let pdfobject_of_cmap pdf cmap =
  match cmap with
  | PredefinedCMap(cmapname) -> Pdf.Name("/" ^ cmapname)
  | CMapFile(res)            -> failwith "cmap file for Type 0 fonts; remains to be implemented."


let pdfobject_of_bbox (xmin, ymin, xmax, ymax) =
  Pdf.Array[Pdf.Integer(xmin); Pdf.Integer(ymin); Pdf.Integer(xmax); Pdf.Integer(ymax)]


module Type0
= struct
    type font = {
        base_font        : string;
        encoding         : cmap;
        descendant_fonts : cid_font;  (* -- represented as a singleton list in PDF -- *)
        to_unicode       : cmap_resource option;
      }


    let of_cid_font cidfont fontname cmap toucopt =
      {
        base_font        = fontname;
        encoding         = cmap;
        descendant_fonts = cidfont;
        to_unicode       = toucopt;
      }


    let add_font_descriptor pdf fontdescr base_font =
      let dcdr =
        match !(fontdescr.font_data) with
        | Data(d) -> d
        | _       -> assert false
      in
      let irstream = add_stream_of_decoder pdf dcdr (Some("OpenType")) () in
        (* -- add to the PDF the stream in which the font file is embedded -- *)
      let objdescr =
        Pdf.Dictionary[
          ("/Type"       , Pdf.Name("/FontDescriptor"));
          ("/FontName"   , Pdf.Name("/" ^ base_font));
          ("/Flags"      , Pdf.Integer(4));  (* temporary; should be variable *)
          ("/FontBBox"   , pdfobject_of_bbox fontdescr.font_bbox);  (* temporary; should be variable *)
          ("/ItalicAngle", Pdf.Real(fontdescr.italic_angle));
          ("/Ascent"     , Pdf.Integer(fontdescr.ascent));
          ("/Descent"    , Pdf.Integer(fontdescr.descent));
          ("/StemV"      , Pdf.Real(fontdescr.stemv));
          ("/FontFile3"  , Pdf.Indirect(irstream));
        ]
      in
      let irdescr = Pdf.addobj pdf objdescr in
        irdescr


    let pdfdict_of_cid_system_info cidsysinfo =
      Pdf.Dictionary[
        ("/Registry", Pdf.String(cidsysinfo.registry));
        ("/Ordering", Pdf.String(cidsysinfo.ordering));
        ("/Supplement", Pdf.Integer(cidsysinfo.supplement));
      ]


    let pdfarray_of_widths dcdr =
      let gmtbl = dcdr.glyph_metrics_table in
      let arr =
        gmtbl |> GlyphMetricsTable.fold (fun gid (w, _, _) acc ->
          Pdf.Integer(gid) :: Pdf.Array[Pdf.Integer(w)] :: acc
        ) []
      in
        Pdf.Array(arr)


    let add_cid_type_0 pdf cidty0font dcdr =
      let cidsysinfo = cidty0font.CIDFontType0.cid_system_info in
      let base_font  = cidty0font.CIDFontType0.base_font in
      let fontdescr  = cidty0font.CIDFontType0.font_descriptor in
      let irdescr = add_font_descriptor pdf fontdescr base_font in
      let objdescend =
        Pdf.Dictionary[
          ("/Type"          , Pdf.Name("/Font"));
          ("/Subtype"       , Pdf.Name("/CIDFontType0"));
          ("/BaseFont"      , Pdf.Name("/" ^ base_font));
          ("/CIDSystemInfo" , pdfdict_of_cid_system_info cidsysinfo);
          ("/FontDescriptor", Pdf.Indirect(irdescr));
          ("/W"             , pdfarray_of_widths dcdr);
            (* should add more; /DW, /DW2, /W2 *)
        ]
      in
      let irdescend = Pdf.addobj pdf objdescend in
        irdescend


    let add_cid_type_2 pdf cidty2font dcdr =
      let cidsysinfo = cidty2font.CIDFontType2.cid_system_info in
      let base_font  = cidty2font.CIDFontType2.base_font in
      let fontdescr  = cidty2font.CIDFontType2.font_descriptor in
      let irdescr = add_font_descriptor pdf fontdescr base_font in
      let objdescend =
        Pdf.Dictionary[
          ("/Type"          , Pdf.Name("/Font"));
          ("/Subtype"       , Pdf.Name("/CIDFontType2"));
          ("/BaseFont"      , Pdf.Name("/" ^ base_font));
          ("/CIDSystemInfo" , pdfdict_of_cid_system_info cidsysinfo);
          ("/FontDescriptor", Pdf.Indirect(irdescr));
          ("/W"             , pdfarray_of_widths dcdr);
            (* should add more; /DW, /DW2, /W2, /CIDToGIDMap *)
        ]
      in
      let irdescend = Pdf.addobj pdf objdescend in
        irdescend


    let to_pdfdict pdf ty0font dcdr =
      let cidfont       = ty0font.descendant_fonts in
      let base_font_ty0 = ty0font.base_font in
      let cmap          = ty0font.encoding in
      let irdescend =
        match cidfont with
        | CIDFontType0(cidty0font) -> add_cid_type_0 pdf cidty0font dcdr
        | CIDFontType2(cidty2font) -> add_cid_type_2 pdf cidty2font dcdr
      in
        Pdf.Dictionary[
          ("/Type"           , Pdf.Name("/Font"));
          ("/Subtype"        , Pdf.Name("/Type0"));
          ("/Encoding"       , pdfobject_of_cmap pdf cmap);
          ("/BaseFont"       , Pdf.Name("/" ^ base_font_ty0));  (* -- can be arbitrary name -- *)
          ("/DescendantFonts", Pdf.Array[Pdf.Indirect(irdescend)]);
        ]

  end

type font =
  | Type1    of Type1.font
(*  | Type1C *)
(*  | MMType1 *)
(*  | Type3 *)
  | TrueType of TrueType.font
  | Type0    of Type0.font


let type1 ty1font = Type1(ty1font)

let true_type trtyfont = TrueType(trtyfont)

let cid_font_type_0 cidty0font fontname cmap =
  let toucopt = None in  (* temporary; /ToUnicode; maybe should be variable *)
    Type0(Type0.of_cid_font (CIDFontType0(cidty0font)) fontname cmap toucopt)

let adobe_japan1 = { registry = "Adobe"; ordering = "Japan1"; supplement = 6; }
let adobe_identity = { registry = "Adobe"; ordering = "Identity"; supplement = 0; }


let get_decoder (srcfile : file_path) : decoder =
  let d = get_main_decoder srcfile in
  let kerntbl = get_kerning_table d in
  let ligtbl = get_ligature_table d in
  let gidtbl = GlyphIDTable.create 256 in  (* temporary; initial size of hash tables *)
  let gmtbl = GlyphMetricsTable.create 256 in (* temporary; initial size of hash tables *)
  let (ascent, descent) =
    match Otfm.hhea d with
    | Ok(rcdhhea) -> (rcdhhea.Otfm.hhea_ascender, rcdhhea.Otfm.hhea_descender)
    | Error(e)    -> raise (FontFormatBroken(e))
  in
    {
      main                = d;
      kerning_table       = kerntbl;
      ligature_table      = ligtbl;
      glyph_id_table      = gidtbl;
      glyph_metrics_table = gmtbl;
      default_ascent      = ascent;
      default_descent     = descent;
    }


let match_ligature (dcdr : decoder) (gidlst : glyph_id list) : ligature_matching =
  let ligtbl = dcdr.ligature_table in
    ligtbl |> LigatureTable.match_prefix gidlst


let convert_to_ligatures dcdr gidlst =
  let rec aux acc gidrest =
    match gidrest with
    | []      -> List.rev acc
    | g :: gs ->
        match match_ligature dcdr gidrest with
        | NoMatch                       -> aux (g :: acc) gs
        | MatchExactly(gidlig, gidtail) -> aux (gidlig :: acc) gidtail
  in
    aux [] gidlst


let find_kerning (dcdr : decoder) (gidprev : glyph_id) (gid : glyph_id) : int option =
  let kerntbl = dcdr.kerning_table in
    kerntbl |> KerningTable.find_opt gidprev gid
