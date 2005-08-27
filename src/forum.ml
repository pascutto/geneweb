(* camlp4r *)
(* $Id: forum.ml,v 4.61 2005-08-27 09:19:01 ddr Exp $ *)
(* Copyright (c) 1998-2005 INRIA *)

open Util;
open Config;
open Def;
open Printf;
open TemplAst;

type message =
  { m_time : string;
    m_date : date;
    m_hour : string;
    m_ident : string;
    m_wizard : string;
    m_friend : string;
    m_email : string;
    m_access : string;
    m_subject : string;
    m_wiki : string;
    m_mess : string }
;

value forum_file conf =
  Filename.concat (base_path [] (conf.bname ^ ".gwb")) "forum"
;

(* Black list *)

value match_strings regexp s =
  loop 0 0 where rec loop i j =
    if i == String.length regexp && j == String.length s then True
    else if i == String.length regexp then False
    else if j == String.length s then False
    else if regexp.[i] = s.[j] then loop (i + 1) (j + 1)
    else if regexp.[i] = '*' then
      if i + 1 == String.length regexp then True
      else if regexp.[i + 1] = s.[j] then loop (i + 2) (j + 1)
      else loop i (j + 1)
    else False
;

value can_post conf =
  try
    let fname = List.assoc "forum_exclude_file" conf.base_env in
    let fname = Util.base_path [] fname in
    let ic = open_in fname in
    let rec loop () =
      match try Some (input_line ic) with [ End_of_file -> None ] with
      [ Some line ->
          if match_strings line conf.from then do { close_in ic; False }
          else loop ()
      | None -> do { close_in ic; True } ]
    in
    loop ()
  with
  [ Not_found | Sys_error _ -> True ]
;

(* Print headers *)

value get_var ic lab s =
  let len = String.length lab in
  if String.length s >= len && String.sub s 0 len = lab then
    let start =
      if String.length s > len && s.[len] = ' ' then len + 1 else len
    in
    (String.sub s start (String.length s - start), input_line ic)
  else ("", s)
;

value sp2nbsp lim s =
  loop 0 0 where rec loop i len =
    if i >= String.length s || s.[i] = '\n' then Buff.get len
    else if i > lim && String.length s > lim + 3 then Buff.get len ^ "..."
    else
      let len =
        match s.[i] with
        [ ' ' -> Buff.mstore len "&nbsp;"
        | x -> Buff.store len x ]
      in
      loop (i + 1) len
;

(* Print a message *)

value read_message conf ic =
  try
    let s = input_line ic in
    let (time, s) = get_var ic "Time:" s in
    let ((time, s), deleted) =
      if time = "" then (get_var ic "****:" s, True)
      else ((time, s), False)
    in
    let (date, hour) =
      try
        let i = String.index time ' ' in
        (String.sub time 0 i,
         String.sub time (i + 1) (String.length time - i - 1))
      with
      [ Not_found -> ("", time) ]
    in
    let date =
      try
        let y = int_of_string (String.sub date 0 4) in
        let m = int_of_string (String.sub date 5 2) in
        let d = int_of_string (String.sub date 8 2) in
        Dgreg
          {year = y; month = m; day = d; prec = Sure; delta = 0}
          Dgregorian
      with
      [ Failure _ | Invalid_argument _ -> Dtext date ]
    in
    let (_, s) = get_var ic "From:" s in
    let (ident, s) = get_var ic "Ident:" s in
    let (wizard, s) = get_var ic "Wizard:" s in
    let (friend, s) = get_var ic "Friend:" s in
    let (email, s) = get_var ic "Email:" s in
    let (access, s) = get_var ic "Access:" s in
    let (subject, s) = get_var ic "Subject:" s in
    let (wiki, s) = get_var ic "Wiki:" s in
    let (_, s) = get_var ic "Text:" s in
    let (mess, s) =
      get_mess 0 s where rec get_mess len s =
        if String.length s >= 2 && s.[0] = ' ' && s.[1] = ' ' then
          let s = String.sub s 2 (String.length s - 2) in
          let len = if len = 0 then len else Buff.store len '\n' in
          get_mess (Buff.mstore len s) (input_line ic)
        else (Buff.get len, s)
    in
    let mess =
      {m_time = time; m_date = date; m_hour = hour; m_ident = ident;
       m_wizard = wizard; m_friend = friend; m_email = email;
       m_access = access; m_subject = subject; m_wiki = wiki; m_mess = mess}
    in
    let accessible =
      if deleted then False
      else if access = "priv" && not conf.wizard && not conf.friend then False
      else True
    in
    Some (mess, accessible)
  with
  [ End_of_file -> None ]
;

value get_message conf pos =
  let fname = forum_file conf in
  match
    try Some (Secure.open_in_bin fname) with [ Sys_error _ -> None ]
  with
  [ Some ic ->
      let ic_len = in_channel_length ic in
      do {
        seek_in ic (ic_len - pos);
        let r =
          match read_message conf ic with
          [ Some (m, accessible) ->
              Some (accessible, m, pos, ic_len - pos_in ic, ic_len)
          | None -> None ]
        in
        close_in ic;
        r
      }
  | None -> None ]
;

value backward_pos conf pos =
  let fname = forum_file conf in
  match
    try Some (Secure.open_in_bin fname) with [ Sys_error _ -> None ]
  with
  [ Some ic ->
      let ic_len = in_channel_length ic in
      let sync_txt = "\nTime: " in
      let sync_txt_last = String.length sync_txt - 1 in
      let new_pos =
        loop (ic_len - pos - 1) sync_txt_last where rec loop new_pos i =
          if new_pos = 0 && i = 1 then ic_len
          else if new_pos > 0 then do {
            seek_in ic new_pos;
            let c = input_char ic in
            if c = sync_txt.[i] then
              if i = 0 then ic_len - new_pos - 1
              else loop (new_pos - 1) (i - 1)
            else loop (new_pos - 1) sync_txt_last
          }
          else pos
      in
      do { close_in ic; new_pos }
  | None -> pos ]
;

value passwd_in_file conf =
  match p_getenv conf.base_env "wizard_passwd_file" with
  [ Some "" | None -> False
  | Some _ -> True ]
;

type env 'a =
  [ Vmess of message and option message and int and int and int
  | Vpos of ref int
  | Vother of 'a
  | Vnone ]
;

value get_env v env = try List.assoc v env with [ Not_found -> Vnone ];
value get_vother = fun [ Vother x -> Some x | _ -> None ];
value set_vother x = Vother x;

value rec eval_var conf base env xx loc =
  fun
  [ ["can_post"] -> VVbool (can_post conf)
  | ["message" :: sl] -> eval_message_var conf env sl
  | ["pos"] ->
      match get_env "pos" env with
      [ Vpos r ->
          if r.val < 0 then VVstring "" else VVstring (string_of_int r.val)
      | _ -> raise Not_found ]
  | _ -> raise Not_found ]
and eval_message_var conf env =
  fun
  [ ["access"] ->
      match get_env "mess" env with
      [ Vmess mess _ _ _ _ -> VVstring mess.m_access
      | _ -> raise Not_found ]
  | ["date" :: sl] ->
      match get_env "mess" env with
      [ Vmess mess _ _ _ _ -> eval_date_var conf mess.m_date sl
      | _ -> raise Not_found ]
  | ["email" :: sl] ->
      match get_env "mess" env with
      [ Vmess mess _ _ _ _ -> eval_message_string_var conf mess.m_email sl
      | _ -> raise Not_found ]
  | ["hour"] ->
      match get_env "mess" env with
      [ Vmess mess _ _ _ _ -> VVstring mess.m_hour
      | _ -> raise Not_found ]
  | ["ident" :: sl] ->
      match get_env "mess" env with
      [ Vmess mess _ _ _ _ -> eval_message_string_var conf mess.m_ident sl
      | _ -> raise Not_found ]
  | ["next_pos"] ->
      match get_env "mess" env with
      [ Vmess _ _ pos _ ic_len ->
          loop pos where rec loop pos =
            if pos = ic_len then VVstring ""
            else
              let back_pos = backward_pos conf pos in
              match get_message conf back_pos with
              [ Some (a, _, _, _, _) ->
                  if not a then loop back_pos
                  else if back_pos = pos then VVstring ""
                  else VVstring (string_of_int back_pos)
              | None -> VVstring "" ]
      | _ -> raise Not_found ]
  | ["pos"] ->
      match get_env "mess" env with
      [ Vmess _ _ pos _ _ -> VVstring (string_of_int pos)
      | _ -> raise Not_found ]
  | ["prev_date" :: sl] ->
      match get_env "mess" env with
      [ Vmess _ prev_mess _ _ _ ->
          match prev_mess with
          [ Some mess -> eval_date_var conf mess.m_date sl
          | None -> VVstring "" ]
      | _ -> raise Not_found ]
  | ["prev_pos"] ->
      match get_env "mess" env with
      [ Vmess _ _ pos next_pos ic_len ->
          loop next_pos where rec loop next_pos =
            if next_pos > 0 then
              match get_message conf next_pos with
              [ Some (a, _, next_pos, next_next_pos, _) ->
                  if not a then loop next_next_pos
                  else VVstring (string_of_int next_pos)
              | None -> VVstring "" ]
            else VVstring ""
      | _ -> raise Not_found ]
  | ["subject" :: sl] ->
      match get_env "mess" env with
      [ Vmess mess _ _ _ _ -> eval_message_string_var conf mess.m_subject sl
      | _ -> raise Not_found ]
  | ["text" :: sl] ->
      match get_env "mess" env with
      [ Vmess mess _ _ _ _ -> eval_message_text_var conf mess.m_mess sl
      | _ -> raise Not_found ]
  | ["time"] ->
      match get_env "mess" env with
      [ Vmess mess _ _ _ _ -> VVstring mess.m_time
      | _ -> raise Not_found ]
  | ["wiki"] ->
      match get_env "mess" env with
      [ Vmess mess _ _ _ _ -> VVstring mess.m_wiki
      | _ -> raise Not_found ]
  | ["wizard"] ->
      if passwd_in_file conf then
        match get_env "mess" env with
        [ Vmess mess _ _ _ _ -> VVstring (mess.m_wizard)
        | _ -> raise Not_found ]
      else VVstring ""
  | _ -> raise Not_found ]
and eval_date_var conf date =
  fun
  [ ["month"] ->
      match date with
      [ Dgreg d _ -> VVstring (string_of_int d.month)
      | _ -> VVstring "" ]
  | [] -> VVstring (Date.string_of_date conf date)
  | _ -> raise Not_found ]
and eval_message_text_var conf str =
  fun
  [ ["wiki"] ->
      let s = string_with_macros conf [] str in
      let lines = Wiki.html_of_tlsw conf s in
      let s = String.concat "\n" lines in
      let s = Wiki.syntax_links conf "NOTES" (Notes.file_path conf) s in
      VVstring s
  | sl -> eval_message_string_var conf str sl ]
and eval_message_string_var conf str =
  fun
  [ ["cut"; s] ->
      try VVstring (no_html_tags (sp2nbsp (int_of_string s) str)) with
      [ Failure _ -> raise Not_found ]
  | [] -> VVstring (no_html_tags str)
  | _ -> raise Not_found ]
;

value print_foreach conf base print_ast eval_expr =
  let eval_int_expr env e =
    let s = eval_expr env () e in
    try int_of_string s with [ Failure _ -> raise Not_found ]
  in
  let rec print_foreach env xx loc s sl el al =
    match [s :: sl] with
    [ ["message"] -> print_foreach_message env el al
    | _ -> raise Not_found ]
  and print_foreach_message env el al =
    let (from_pos, max_mess) =
      match el with
      [ [[e1]; [e2]] -> (eval_int_expr env e1, eval_int_expr env e2)
      | _ -> raise Not_found ]
    in
    let fname = forum_file conf in
    match
      try Some (Secure.open_in_bin fname) with [ Sys_error _ -> None ]
    with
    [ Some ic ->
        let ic_len = in_channel_length ic in
        let rec loop prev_mess i =
          if i >= max_mess then pos_in ic
          else
            let pos = ic_len - pos_in ic in
            match read_message conf ic with
            [ Some (mess, accessible) ->
                if not accessible then loop prev_mess i
                else
                  let next_pos = ic_len - pos_in ic in
                  let vmess = Vmess mess prev_mess pos next_pos ic_len in
                  let env = [("mess", vmess) :: env] in
                  do {
                    List.iter (print_ast env ()) al;
                    loop (Some mess) (i + 1);
                  }
            | None -> -1 ]
        in
        do {
          if from_pos < 0 then ()
          else try seek_in ic from_pos with [ Sys_error _ -> () ];
          let pos = loop None 0 in
          match get_env "pos" env with
          [ Vpos r -> r.val := pos
          | _ -> () ];
          close_in ic;
        }
    | None -> () ]
  in
  print_foreach
;

value print conf base =
  let env =
    match p_getint conf.env "p" with
    [ Some pos ->
        match get_message conf pos with
        [ Some (a, mess, _, next_pos, ic_len) ->
            if a then
              [("mess", Vmess mess None pos next_pos ic_len);
               ("pos", Vpos (ref pos))]
            else [("pos", Vpos (ref (-1)))]
        | None -> [("pos", Vpos (ref (-1)))] ]
    | None -> [("pos", Vpos (ref (-1)))] ]
  in
  Templ.interp conf base "forum" (eval_var conf base)
    (fun _ -> Templ.eval_transl conf) (fun _ -> raise Not_found)
    get_vother set_vother (print_foreach conf base) env ()
;

value print_forum_headers conf base =
  let env = [("pos", Vpos (ref (-1)))] in
  Templ.interp conf base "forum" (eval_var conf base)
    (fun _ -> Templ.eval_transl conf) (fun _ -> raise Not_found)
    get_vother set_vother (print_foreach conf base) env ()
;

(* Send a message *)

value print_add conf base = print conf base;

value get conf key =
  match p_getenv conf.env key with
  [ Some v -> v
  | None -> failwith (key ^ " unbound") ]
;

value get1 conf key =
  try Wserver.gen_decode False (List.assoc key conf.env) with
  [ Not_found -> failwith (key ^ " unbound") ]
;

value forum_add conf base ident comm =
  let email = Gutil.strip_spaces (get conf "Email") in
  let subject = Gutil.strip_spaces (get conf "Subject") in
  let access =
    if conf.wizard || conf.friend then
      match p_getenv conf.env "priv_acc" with
      [ Some _ -> "priv"
      | None -> "publ" ]
    else "publ"
  in
  if ident <> "" && comm <> "" then
    let fname = forum_file conf in
    let tmp_fname = fname ^ "~" in
    let oc = Secure.open_out tmp_fname in
    try
      let (hh, mm, ss) = conf.time in
      do {
        fprintf oc "Time: %04d-%02d-%02d %02d:%02d:%02d\n"
          conf.today.year conf.today.month conf.today.day hh mm ss;
        fprintf oc "From: %s\n" conf.from;
        fprintf oc "Ident: %s\n" ident;
        if (conf.wizard || conf.just_friend_wizard) && conf.user <> ""
        then
          fprintf oc "Wizard: %s\n" conf.user
        else ();
        if conf.friend && not conf.just_friend_wizard && conf.user <> "" then
          fprintf oc "Friend: %s\n" conf.user
        else ();
        if email <> "" then fprintf oc "Email: %s\n" email else ();
        fprintf oc "Access: %s\n" access;
        let subject = if subject = "" then "-" else subject in
        fprintf oc "Subject: %s\n" subject;
        fprintf oc "Wiki: on\n";
        fprintf oc "Text:\n";
        let rec loop i bol =
          if i == String.length comm then ()
          else do {
            if bol then fprintf oc "  " else ();
            if comm.[i] <> '\r' then output_char oc comm.[i] else ();
            loop (i + 1) (comm.[i] = '\n')
          }
        in
        loop 0 True;
        fprintf oc "\n\n";
        match
          try
            Some (Secure.open_in_bin fname) with
            [ Sys_error _ -> None ]
        with
        [ Some ic ->
            do {
              try while True do { output_char oc (input_char ic) } with
              [ End_of_file -> () ];
              close_in ic;
            }
        | _ -> () ];
        close_out oc;
        try Sys.remove fname with [ Sys_error _ -> () ];
        Sys.rename tmp_fname fname;
      }
    with e ->
      do {
        try close_out oc with _ -> ();
        try Sys.remove tmp_fname with [ Sys_error _ -> () ];
        raise e
      }
  else ()
;

value print_add_ok conf base =
  let ident = Gutil.strip_spaces (get conf "Ident") in
  let comm = Gutil.gen_strip_spaces False (get1 conf "Text") in
  if not (can_post conf) then incorrect_request conf
  else if ident = "" || comm = "" then print conf base
  else
    let title _ =
      Wserver.wprint "%s" (capitale (transl conf "message added"))
    in
    try
      do {
        forum_add conf base ident comm;
        header conf title;
        print_link_to_welcome conf True;
        Wserver.wprint "<a href=\"%sm=FORUM\">%s</a>\n" (commd conf)
          (capitale (transl conf "database forum"));
        trailer conf;
      }
    with
    [ Update.ModErr -> () ]
;

(* Deleting a message *)

value internal_error conf base =
  let title _ = Wserver.wprint "%s" (capitale (transl conf "error")) in
  do {
    rheader conf title;
    Wserver.wprint "<em>internal error</em>\n";
    trailer conf;
    raise Update.ModErr
  }
;

value forum_del conf base pos next_pos =
  let fname = forum_file conf in
  let tmp_fname = fname ^ "~" in
  match
     try Some (Secure.open_in_bin fname) with [ Sys_error _ -> None ]
  with
  [ Some ic ->
      let oc = Secure.open_out tmp_fname in
      let len = in_channel_length ic in
      let pos = len - pos in
      do {
        loop 0 where rec loop i =
          if i = len then ()
          else
            let c = input_char ic in
            do {
              if i < pos || i >= pos + 4 then output_char oc c
              else output_char oc '*';
              loop (i + 1);
            };
        close_in ic;
        close_out oc;
        try Sys.remove fname with [ Sys_error _ -> () ];
        Sys.rename tmp_fname fname;
      }
  | None -> internal_error conf base ]
;

value print_del_ok conf base =
  let title _ =
    Wserver.wprint "%s" (capitale (transl conf "message deleted"))
  in
  do {
    header conf title;
    print_link_to_welcome conf True;
    Wserver.wprint "<a href=\"%sm=FORUM\">%s</a>\n" (commd conf)
      (capitale (transl conf "database forum"));
    trailer conf;
  }
;

value delete_forum_message conf base pos =
  match get_message conf pos with
  [ Some (a, m, _, next_pos, forum_length) ->
      if a && conf.wizard && conf.user <> "" && m.m_wizard = conf.user &&
        passwd_in_file conf
      then
        try
          do {
            forum_del conf base pos next_pos;
            print_del_ok conf base;
          }
        with
        [ Update.ModErr -> () ]
      else print_forum_headers conf base
  | None -> print_forum_headers conf base ]
;

value print_del conf base =
  match p_getint conf.env "p" with
  [ Some pos -> delete_forum_message conf base pos
  | None -> print_forum_headers conf base ]
;
