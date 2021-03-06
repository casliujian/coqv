open Printf
open Runtime
open Types
open Lexing
open Interface
open Cmd
open Proof_model
open History
open Feedback
open Util
open Stateid
open CSig
(*open Pp*)
(*open Parser*)

type request_mode = 
      Request_add           
    | Request_edit_at of Stateid.t
    | Request_query     
    | Request_goals
    | Request_evars         | Request_hints         | Request_status    | Request_search 
    | Request_getoptions    | Request_setoptions    | Request_mkcases   | Request_quit
    | Request_about         | Request_init          | Request_interp    | Request_stopworker 
    | Request_printast      | Request_annotate

let request_mode = ref Request_about 

let goal_to_label goal = 
    let raw_hyp_list = goal.goal_hyp in
        (*Serialize.to_list Serialize.to_string goal.goal_hyp in*)
        (*List.map (fun h -> Serialize.to_list Serialize.to_string h) goal.goal_hyp in*)
    let hyp_list = List.map (fun h ->
            let ch = caught_str h in
            let split_pos = String.index ch ':' in
            let hn, hc = String.sub ch 0 (split_pos), String.sub ch (split_pos+1) (String.length ch - split_pos-1) in
            String.trim hn, String.trim hc 
        ) raw_hyp_list in
    let conc = String.trim (caught_str goal.goal_ccl) in
    {
        id = goal.goal_id;
        hypos = hyp_list;
        conclusion = conc;
    }


let print_xml chan xml =
  let rec print = function
  | Xml_datatype.PCData s -> output_string chan s
  | Xml_datatype.Element (_, _, children) -> List.iter print children
  in
  print xml
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
        print_endline ("got new stateid: "^(string_of_int stateid)); 
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
    match msg with
    | Good None -> 
        print_endline "no more goals";
        Doc_model.raise_cache ()
    | Good (Some goals) -> begin
            printf "focused goals number: %d," (List.length (goals.fg_goals));
            Doc_model.raise_cache ();
            begin
                match !Cmd.current_cmd_type with
                | Module modul_name -> moduls := (create_module modul_name) :: !moduls
                | End modul_name -> closing_modul modul_name
                | Proof (thm_name, kind) -> 
                    let goal = List.hd (goals.fg_goals) in
                    let label = goal_to_label goal in
                    let rec node : node = {
                        id = goal.goal_id;
                        label = label;
                        state = Chosen;
                        parent = node;
                    } in
                    let proof_tree = new_proof_tree node in
                    let session = new_session thm_name kind Processing proof_tree in
                    current_session_id := Some thm_name;
                    add_session_to_modul (List.hd !moduls) session;
                    History.record_step !Runtime.new_stateid (Add_node node.id)
                | Qed -> ()
                | Other -> 
                    let fg_goals = goals.fg_goals in
                    let chosen_node = select_chosen_node () in
                    match chosen_node with
                    | None -> print_endline "No focus node, maybe the proof tree is complete"
                    | Some cnode -> 
                        let new_nodes : node list = List.map (fun g -> 
                        {
                            id = g.goal_id;
                            label = goal_to_label g;
                            state = To_be_chosen;
                            parent = cnode;
                        }) fg_goals in
                        if List.length new_nodes = 0 then begin
                            History.record_step !Runtime.new_stateid (Change_state (cnode.id, cnode.state));
                            change_node_state cnode.id Proved
                        end else begin
                             let node, other_nodes = List.hd new_nodes, List.tl new_nodes in
                        match chosen_node with
                        | None -> print_endline "No focus node, maybe the proof tree is complete"
                        | Some cnode -> 
                            List.iter (fun (n:node) ->
                                if not (node_exists n.id) then begin
                                    add_edge cnode n (snd (List.hd !Doc_model.doc));
                                    History.record_step !Runtime.new_stateid (Add_node n.id);
                                    History.record_step !Runtime.new_stateid (Change_state (cnode.id, cnode.state));
                                    cnode.state <- Not_proved;
                                    n.state <- To_be_chosen;
                                end
                            ) new_nodes;
                            History.record_step !Runtime.new_stateid (Change_state (node.id, node.state));
                            node.state <- Chosen   
                        end
                    (*if List.length new_nodes = 0 then begin
                        match chosen_node with
                        | None -> print_endline "No focus node, maybe the proof tree is complete"
                        | Some cnode -> 
                            History.record_step !Runtime.new_stateid (Change_state (cnode.id, cnode.state));
                            change_node_state cnode.id Proved
                    end else begin
                        let node, other_nodes = List.hd new_nodes, List.tl new_nodes in
                        match chosen_node with
                        | None -> print_endline "No focus node, maybe the proof tree is complete"
                        | Some cnode -> 
                            List.iter (fun n ->
                                if not (node_exists n.id) then begin
                                    add_edge cnode n (snd (List.hd !Doc_model.doc));
                                    History.record_step !Runtime.new_stateid (Add_node n.id);
                                    History.record_step !Runtime.new_stateid (Change_state (cnode.id, cnode.state));
                                    cnode.state <- Not_proved;
                                    n.state <- To_be_chosen;
                                end
                            ) new_nodes;
                            History.record_step !Runtime.new_stateid (Change_state (node.state));
                            node.state <- Chosen
                    end*)
            end
        end
    | Fail _ -> Doc_model.clear_cache ()

let request_add cmd editid stateid verbose = 
    let ecmd = cmd in
    let cout = Runtime.coq_channels.cout in
    request_mode := Request_add;
    let add = Xmlprotocol.add ((ecmd, editid), (stateid, verbose)) in
    let xml_add = Xmlprotocol.of_call add in
    print_endline ("call add:\n"^(Xmlprotocol.pr_call add));
    print_endline ("xml call add:\n"^(Xml_printer.to_string_fmt xml_add));
    Xml_printer.print (Xml_printer.TChannel cout) xml_add;
    Doc_model.cache := Some (stateid, cmd)

let response_add msg =
    begin
        match msg with
        | Good (stateid, (CSig.Inl (), content)) ->
            printf "new state id: %d, message content: %s\n" stateid content;
            Runtime.new_stateid := stateid;
            flush stdout
        | Good (stateid, (CSig.Inr next_stateid, content)) ->
            printf "finished current proof, move to state id: %d, message content: %s\n" next_stateid content;
            Runtime.new_stateid := next_stateid;
            flush stdout
        | Fail (stateid, _, content) -> 
            printf "error add in state id %d, message content: %s\n" stateid content;
            Doc_model.clear_cache ();
            flush stdout
    end;
    request_goals ()

let request_edit_at stateid = 
    let cout = Runtime.coq_channels.cout in
    request_mode := Request_edit_at stateid;
    let editat = Xmlprotocol.edit_at stateid in
    let xml_editat = Xmlprotocol.of_call editat in
    Xml_printer.print (Xml_printer.TChannel cout) xml_editat

let response_edit_at msg stateid =
    match msg with
    | Good (CSig.Inl ()) ->
        printf "simple backtract;\n";
        flush stdout;
        Doc_model.move_focus_to stateid;
        Runtime.new_stateid := stateid;
        History.undo_upto stateid
    | Good (CSig.Inr (focusedStateId, (focusedQedStateId, oldFocusedStateId))) ->
        printf "focusedStateId: %d, focusedQedStateId: %d, oldFocusedStateId: %d\n" focusedStateId focusedQedStateId oldFocusedStateId;
        flush stdout;
        Doc_model.move_focus_to stateid;
        Runtime.new_stateid := stateid;
        History.undo_upto stateid
    | Fail (errorFreeStateId, loc, content) ->
        printf "errorFreeStateId: %d, message content: %s\n" errorFreeStateId content;
        request_edit_at errorFreeStateId

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
    let fb = Feedback.to_feedback xml_fb in
    begin
        match fb.id with
        | Edit editid -> printf "editid: %d\n" editid
        | State stateid -> printf "stateid: %d\n" stateid
    end;
    printf "contents: ";
    begin
        match fb.contents with 
        | Processed -> printf "Processed"
        | Incomplete -> printf "Incomplete"
        | Complete -> printf "Complete"
        | ErrorMsg (loc, str) -> printf "ErrorMsg: %s" str
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
        | Message message -> printf "Message %s: %s" (str_message_level message.message_level) message.message_content
    end;
    printf "\n";
    printf "route: %d\n" fb.route;
    flush stdout

let interpret_cmd cmd = 
    printf "Interpreting command: %s\n" cmd;
    if cmd = "init" then
        request_init None;
    flush stdout

let handle_input input_str cout = 
    output_string stdout (input_str^"\n");
    Cmd.current_cmd_type := Cmd.get_cmd_type input_str;
    request_mode := Request_init;
    print_endline ((Cmd.escaped_str input_str)^", -1,"^(string_of_int !Runtime.new_stateid)^", true");
    request_add (input_str) (-1) !Runtime.new_stateid true;
    flush stdout


let handle_answer feedback = 
    let fb_str = Str.global_replace (ignored_re ()) "" feedback in
    printf "got feedback message length: %d\n" (String.length fb_str);
    printf "received: %s\n\n" fb_str;
    if not !Flags.xml then begin
        printf "%s\n" fb_str
    end else begin
        let xparser = Xml_parser.make (Xml_parser.SString fb_str) in
        let xml_fb = Xml_parser.parse xparser in
        if Feedback.is_message xml_fb then begin
            let message = Feedback.to_message xml_fb in
            printf "%s: %s\n" (str_message_level message.message_level) message.message_content;
            flush stdout
        end else if Feedback.is_feedback xml_fb then begin
            (*print_endline "printing xml:";
            print_xml stdout xml_fb;*)
            interpret_feedback xml_fb
        end else begin
                match !request_mode with
                | Request_about ->      response_coq_info (Xmlprotocol.to_answer (Xmlprotocol.About ()) xml_fb)
                | Request_init ->       response_init (Xmlprotocol.to_answer (Xmlprotocol.init None) xml_fb)
                | Request_edit_at stateid -> response_edit_at (Xmlprotocol.to_answer (Xmlprotocol.edit_at 0) xml_fb) stateid
                | Request_query ->      response_query (Xmlprotocol.to_answer (Xmlprotocol.query ("", 0)) xml_fb)
                | Request_goals ->      response_goals (Xmlprotocol.to_answer (Xmlprotocol.goals ()) xml_fb)
                | Request_evars ->      response_evars (Xmlprotocol.to_answer (Xmlprotocol.evars ()) xml_fb)
                | Request_hints ->      response_hints (Xmlprotocol.to_answer (Xmlprotocol.hints ()) xml_fb)
                | Request_status ->     response_status (Xmlprotocol.to_answer (Xmlprotocol.status true) xml_fb)
                | Request_search ->     response_search (Xmlprotocol.to_answer (Xmlprotocol.search []) xml_fb)
                | Request_getoptions -> response_getoptions (Xmlprotocol.to_answer (Xmlprotocol.get_options ()) xml_fb)
                | Request_setoptions -> response_setoptions (Xmlprotocol.to_answer (Xmlprotocol.set_options []) xml_fb)
                | Request_mkcases ->    response_mkcases (Xmlprotocol.to_answer (Xmlprotocol.mkcases "") xml_fb)
                | Request_quit ->       response_quit (Xmlprotocol.to_answer (Xmlprotocol.quit ()) xml_fb)
                | Request_add ->        response_add (Xmlprotocol.to_answer (Xmlprotocol.add (("",0),(0,true))) xml_fb)
                | Request_interp ->     response_interp (Xmlprotocol.to_answer (Xmlprotocol.interp ((true, true),"")) xml_fb)
                | Request_stopworker -> response_stopworker (Xmlprotocol.to_answer (Xmlprotocol.stop_worker "") xml_fb)
                | Request_printast ->   response_printast (Xmlprotocol.to_answer (Xmlprotocol.print_ast 0) xml_fb)
                | Request_annotate ->   response_annotate (Xmlprotocol.to_answer (Xmlprotocol.annotate "") xml_fb)
            end
    end