open Printf
open Runtime
open Types
open Lexing
open Interface
(* open Cmd *)
open Proof_model
open History
open Feedback
open Util
open Stateid
open CSig
open Callbacks
open Coqv_utils
(*open Parser*)

type request_mode = 
      Request_add of string    
    | Request_edit_at of Stateid.t
    | Request_query     
    | Request_goals
    | Request_evars         | Request_hints         | Request_status    | Request_search 
    | Request_getoptions    | Request_setoptions    | Request_mkcases   | Request_quit
    | Request_about         | Request_init          | Request_interp    | Request_stopworker 
    | Request_printast      | Request_annotate

let request_mode = ref Request_about 

(*************************************************************************************)
(**sending xml characters to coqtop**)

let request_coq_info cout = 
    request_mode := Request_about;
    let about = Xmlprotocol.About () in
    let xml_about = Xmlprotocol.of_call about in
    Xml_printer.print (Xml_printer.TChannel cout) xml_about

let response_coq_info fb_val = 
    (match fb_val with
    | Good fb -> 
            Runtime.coqtop_info := fb;
            printf "Coqtop Info: \n\tversion %s, \n\tprotocol version %s, \n\trelease date %s, \n\tand compile date %s\n" 
                fb.coqtop_version fb.protocol_version fb.release_date fb.compile_date
    | _ -> printf "parsing coq info message fails\n");
    flush stdout

let request_init filename = 
    let cout = Runtime.coq_channels.cout in
    request_mode := Request_init;
    let init = Xmlprotocol.init filename in
    let xml_init = Xmlprotocol.of_call init in
    Xml_printer.print (Xml_printer.TChannel cout) xml_init

let response_init msg = 
    match msg with
    | Good stateid -> 
        (*print_endline ("got new stateid: "^(string_of_int stateid)); *)
        Runtime.new_stateid := stateid
    | _ -> printf "unknown from response init\n"; flush stdout    

let request_quit cout = 
    request_mode := Request_quit;
    let quit = Xmlprotocol.quit () in
    let xml_quit = Xmlprotocol.of_call quit in
    Xml_printer.print (Xml_printer.TChannel cout) xml_quit

let response_quit msg = 
    match msg with
    | Good _ -> 
        print_endline ("now quit! "); 
        Runtime.running := false
    | _ -> printf "unknown from response quit\n"; flush stdout  

let request_goals () =
    let cout = Runtime.coq_channels.cout in 
    request_mode := Request_goals;
    let goals = Xmlprotocol.goals () in
    let xml_goals = Xmlprotocol.of_call goals in
    Xml_printer.print (Xml_printer.TChannel cout) xml_goals

let response_goals msg =
    (*print_endline "received response from goals.................";*)
    match msg with
    | Good None -> 
        print_endline "**************no more goals****************";
        begin
            match !Runtime.current_cmd_type with
            | Qed -> 
                current_session_id := None;
                History.record_step !Runtime.new_stateid Dummy
            | _ -> ()
        end
    | Good (Some goals) -> on_receive_goals !Runtime.current_cmd_type goals
    | Fail _ -> 
        print_endline "fail to get goals"

let request_add cmd editid stateid verbose = 
    let ecmd = cmd in
    let cout = Runtime.coq_channels.cout in
    request_mode := Request_add cmd;
    let add = Xmlprotocol.add ((ecmd, editid), (stateid, verbose)) in
    let xml_add = Xmlprotocol.of_call add in
    Xml_printer.print (Xml_printer.TChannel cout) xml_add;
    Doc_model.cache := Some (stateid, cmd)

let response_add msg cmd =
    begin
        match msg with
        | Good (stateid, (CSig.Inl (), content)) ->
            if String.trim content <> "" then 
                printf "new state id: %d, message content: %s\n" stateid content;
            Runtime.new_stateid := stateid;
            Doc_model.add_to_doc (stateid, cmd);
            flush stdout
        | Good (stateid, (CSig.Inr next_stateid, content)) ->
            if String.trim content <> "" then 
                printf "finished current proof, move to state id: %d, message content: %s\n" next_stateid content;
            Runtime.new_stateid := next_stateid;
            Doc_model.add_to_doc (next_stateid, cmd);
            flush stdout
        | Fail (stateid, _, xml_content) -> 
            printf "error add in state id %d, message content: " stateid;
            print_xml stdout xml_content;
            print_endline "";
            (*Doc_model.clear_cache ();*)
            flush stdout
    end;
    (*Thread.delay 0.001;*)
    request_goals ();
    flush coq_channels.cout

let request_edit_at stateid = 
    let cout = Runtime.coq_channels.cout in
    request_mode := Request_edit_at stateid;
    let editat = Xmlprotocol.edit_at stateid in
    let xml_editat = Xmlprotocol.of_call editat in
    Xml_printer.print (Xml_printer.TChannel cout) xml_editat

let response_edit_at msg stateid =
    begin
        match msg with
        | Good (CSig.Inl ()) ->
            printf "simple backtract;\n";
            flush stdout;
            on_edit_at stateid
        | Good (CSig.Inr (focusedStateId, (focusedQedStateId, oldFocusedStateId))) ->
            printf "focusedStateId: %d, focusedQedStateId: %d, oldFocusedStateId: %d\n" focusedStateId focusedQedStateId oldFocusedStateId;
            flush stdout;
            on_edit_at stateid
            (* Doc_model.move_focus_to stateid;
            Runtime.new_stateid := stateid;
            History.undo_upto stateid *)
        | Fail (errorFreeStateId, loc, xml_content) ->
            printf "errorFreeStateId: %d, message content: " errorFreeStateId;
            print_xml stdout xml_content;
            print_endline "";
            flush stdout;
            request_edit_at errorFreeStateId
    end;
    request_goals (); (*fetch goals after edit at some new stateid*)
    flush coq_channels.cout

let request_query query stateid = 
    let cout = Runtime.coq_channels.cout in
    request_mode := Request_query;
    let query = Xmlprotocol.query query in
    let xml_query = Xmlprotocol.of_call query in
    Xml_printer.print (Xml_printer.TChannel cout) xml_query

let response_query msg = 
    match msg with
    | Good query -> print_endline query
    | _ -> printf "unknown from response query\n"; flush stdout

let request_evars () = 
    let cout = Runtime.coq_channels.cout in
    request_mode := Request_evars;
    let evars = Xmlprotocol.evars () in
    let xml_evars = Xmlprotocol.of_call evars in
    Xml_printer.print (Xml_printer.TChannel cout) xml_evars

let response_evars msg =
    print_endline "response evars, not finished."

let request_hints () = 
    let cout = Runtime.coq_channels.cout in
    request_mode := Request_hints;
    let hints = Xmlprotocol.hints () in
    let xml_hints = Xmlprotocol.of_call hints in
    Xml_printer.print (Xml_printer.TChannel cout) xml_hints

let response_hints msg =
    print_endline "response hints, not finished."

let request_status force = 
    let cout = Runtime.coq_channels.cout in
    request_mode := Request_status;
    let status = Xmlprotocol.status force in
    let xml_status = Xmlprotocol.of_call status in
    Xml_printer.print (Xml_printer.TChannel cout) xml_status

let response_status msg =
    print_endline "response status, not finished"

let request_search search_list = 
    let cout = Runtime.coq_channels.cout in
    request_mode := Request_search;
    let search = Xmlprotocol.search search_list in
    let xml_search = Xmlprotocol.of_call search in
    Xml_printer.print (Xml_printer.TChannel cout) xml_search

let response_search msg = 
    print_endline "response search, not finished"

let request_getoptions () = 
    let cout = Runtime.coq_channels.cout in
    request_mode := Request_getoptions;
    let getoptions = Xmlprotocol.get_options () in
    let xml_getoptions = Xmlprotocol.of_call getoptions in
    Xml_printer.print (Xml_printer.TChannel cout) xml_getoptions

let response_getoptions msg = 
    print_endline "response getoptions, not finished"

let request_setoptions options = 
    let cout = Runtime.coq_channels.cout in
    request_mode := Request_setoptions;
    let setoptions = Xmlprotocol.set_options options in
    let xml_setoptions = Xmlprotocol.of_call setoptions in
    Xml_printer.print (Xml_printer.TChannel cout) xml_setoptions

let response_setoptions msg = 
    print_endline "response setoptions, not finished"

let request_mkcases str = 
    let cout = Runtime.coq_channels.cout in
    request_mode := Request_mkcases;
    let mkcases = Xmlprotocol.mkcases str in
    let xml_mkcases = Xmlprotocol.of_call mkcases in
    Xml_printer.print (Xml_printer.TChannel cout) xml_mkcases

let response_mkcases msg = 
    print_endline "response mkcases, not finished"

let request_interp interp = 
    let cout = Runtime.coq_channels.cout in
    request_mode := Request_interp;
    let interp = Xmlprotocol.interp interp in
    let xml_interp = Xmlprotocol.of_call interp in
    Xml_printer.print (Xml_printer.TChannel cout) xml_interp

let response_interp msg = 
    print_endline "response interp, not finished"

let request_stopworker str = 
    let cout = Runtime.coq_channels.cout in
    request_mode := Request_stopworker;
    let stopworker = Xmlprotocol.stop_worker str in
    let xml_stopworker = Xmlprotocol.of_call stopworker in
    Xml_printer.print (Xml_printer.TChannel cout) xml_stopworker

let response_stopworker msg = 
    print_endline "response stopworker, not finished"

let request_printast stateid = 
    let cout = Runtime.coq_channels.cout in
    request_mode := Request_printast;
    let printast = Xmlprotocol.print_ast stateid in
    let xml_printast = Xmlprotocol.of_call printast in
    Xml_printer.print (Xml_printer.TChannel cout) xml_printast

let response_printast msg = 
    print_endline "response printast, not finished"

let request_annotate str = 
    let cout = Runtime.coq_channels.cout in
    request_mode := Request_annotate;
    let annotate = Xmlprotocol.annotate str in
    let xml_annotate = Xmlprotocol.of_call annotate in
    Xml_printer.print (Xml_printer.TChannel cout) xml_annotate

let response_annotate msg = 
    print_endline "response annotate, not finished"



(*************************************************************************************)

let interpret_feedback xml_fb = 
    let fb = Xmlprotocol.to_feedback xml_fb in
    begin
        match fb.id with
        | Edit editid -> printf "editid: %d, " editid
        | State stateid -> printf "stateid: %d, " stateid
    end;
    printf "";
    begin
        match fb.contents with 
        | Processed -> printf "Processed"
        | Incomplete -> printf "Incomplete"
        | Complete -> printf "Complete"
        | ProcessingIn worker_name -> printf "ProcessingIn worker %s" worker_name
        | InProgress i -> printf "InProgress %d" i 
        | WorkerStatus (worker_name, status) -> printf "WorkerStatus: %s --> %s" worker_name status
        | Goals (loc, str) -> printf "Goals: %s" str 
        | AddedAxiom -> printf "AddedAxiom"
        | GlobRef _ -> printf "GlobRef ..."
        | GlobDef _ -> printf "GlobDef ..."
        | FileDependency _ -> printf "FileDependency ..."
        | FileLoaded (module_name, vofile_name) -> printf "FileLoaded: %s from %s" module_name vofile_name
        | Custom _ -> printf "Custom ..."
        | Message (levl, loc, xml_content) -> printf "Message %s" (str_feedback_level levl); print_xml stdout xml_content
    end;
    printf "\n";
    (*printf "route: %d\n" fb.route;*)
    flush stdout

let interpret_cmd cmd_str_list = 
    let running_coqv = ref true in
    begin
        match cmd_str_list with
        | [] -> ()
        | cmd :: options -> 
        (*printf "Interpreting command: %s\n" cmd;*)
        begin
            match cmd with
            | "init" -> request_init None; running_coqv := false
            | "status" -> print_endline (Status.str_status ())
            | "history" -> print_endline (History.str_history ())
            | "proof" -> 
                if options = [] then
                    begin
                        match !Proof_model.current_session_id with
                        | None -> print_endline "not in proof mode"
                        | Some sname -> print_endline (Status.str_proof_tree sname)    
                    end
                else 
                    List.iter (fun a -> print_endline (Status.str_proof_tree a)) options
            | "undo_to" ->
                let new_stateid = int_of_string (List.hd options) in
                request_edit_at new_stateid
            | _ -> print_endline "command not interpreted."
        end
    end;
    !running_coqv

let handle_input input_str cout = 
    (*output_string stdout (input_str^"\n");*)
    Runtime.current_cmd_type := get_cmd_type input_str;
    (*print_endline ("current_cmd_type: "^(Cmd.str_cmd_type !Cmd.current_cmd_type));*)
    (*request_mode := Request_init;*)
    request_add (input_str) (-1) !Runtime.new_stateid true;
    flush stdout

let other_xml_str xml_str tag = 
    let xml_str_list = Str.split (Str.regexp tag) xml_str in
    let prefix_length = String.length (List.nth xml_str_list 0) + String.length tag in
    let other_str = String.trim (String.sub xml_str prefix_length (String.length xml_str - prefix_length)) in
    other_str

let handle_answer received_str = 
    let fb_str = Str.global_replace (ignored_re ()) "" received_str in
    (*printf "got feedback message length: %d\n" (String.length fb_str);
    printf "received: %s\n\n" fb_str;*)
    let handle str = 
        let xparser = Xml_parser.make (Xml_parser.SString str) in
        let xml_str = Xml_parser.parse xparser in
        match Xmlprotocol.is_message xml_str with
        | Some (level, loc, content) ->
            printf "%s: " (str_feedback_level level);
            print_xml stdout content;
            print_endline "";
            flush stdout;
            other_xml_str str "</message>"            
        | None -> 
            if Xmlprotocol.is_feedback xml_str then begin
                (*interpret_feedback xml_str;*)
                other_xml_str str "</feedback>"    
            end else begin
                begin
                    match !request_mode with
                    | Request_about ->      response_coq_info (Xmlprotocol.to_answer (Xmlprotocol.About ()) xml_str)
                    | Request_init ->       
                        response_init (Xmlprotocol.to_answer (Xmlprotocol.init None) xml_str)
                    | Request_edit_at stateid -> response_edit_at (Xmlprotocol.to_answer (Xmlprotocol.edit_at 0) xml_str) stateid
                    | Request_query ->      response_query (Xmlprotocol.to_answer (Xmlprotocol.query ("", 0)) xml_str)
                    | Request_goals ->      
                        response_goals (Xmlprotocol.to_answer (Xmlprotocol.goals ()) xml_str)
                    | Request_evars ->      response_evars (Xmlprotocol.to_answer (Xmlprotocol.evars ()) xml_str)
                    | Request_hints ->      response_hints (Xmlprotocol.to_answer (Xmlprotocol.hints ()) xml_str)
                    | Request_status ->     response_status (Xmlprotocol.to_answer (Xmlprotocol.status true) xml_str)
                    | Request_search ->     response_search (Xmlprotocol.to_answer (Xmlprotocol.search []) xml_str)
                    | Request_getoptions -> response_getoptions (Xmlprotocol.to_answer (Xmlprotocol.get_options ()) xml_str)
                    | Request_setoptions -> response_setoptions (Xmlprotocol.to_answer (Xmlprotocol.set_options []) xml_str)
                    | Request_mkcases ->    response_mkcases (Xmlprotocol.to_answer (Xmlprotocol.mkcases "") xml_str)
                    | Request_quit ->       response_quit (Xmlprotocol.to_answer (Xmlprotocol.quit ()) xml_str)
                    | Request_add cmd ->        
                        response_add (Xmlprotocol.to_answer (Xmlprotocol.add (("",0),(0,true))) xml_str) cmd
                    | Request_interp ->     response_interp (Xmlprotocol.to_answer (Xmlprotocol.interp ((true, true),"")) xml_str)
                    | Request_stopworker -> response_stopworker (Xmlprotocol.to_answer (Xmlprotocol.stop_worker "") xml_str)
                    | Request_printast ->   response_printast (Xmlprotocol.to_answer (Xmlprotocol.print_ast 0) xml_str)
                    | Request_annotate ->   response_annotate (Xmlprotocol.to_answer (Xmlprotocol.annotate "") xml_str)
                end;
                other_xml_str str "</value>"
            end in
    let to_be_handled = ref fb_str in
    while !to_be_handled <> "" do
        to_be_handled := handle !to_be_handled
    done
    