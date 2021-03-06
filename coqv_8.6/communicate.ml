open Printf
open Types
open Yojson

type message = 
    | Create_session of string * string * string * (node_state list)
    | Remove_session of string
    | Add_node of string * node
    | Remove_node of string * string
    | Add_edge of string * string * string * string
    | Remove_edge of string * string * string
    | Change_node_state of string * string * node_state
    | Highlight_node of string * string
    | Unhighlight_node of string * string
    | Feedback_ok of string
    | Feedback_fail of string * string

type visualize_agent =
    {
        mutable input: in_channel;
        mutable output: out_channel;
        mutable is_alive: bool;
        sending_queue: message Queue.t;
        sending_mutex: Mutex.t;
        sending_conditional: Condition.t;
    }



(*let protocol_version_no = "20170502"*)

let log_file = "log"

(*let vin = ref stdin
let vout = ref stdout*)


(*let receiving_queue = Queue.create ()*)

(*let handshake cin cout = 
    output_string cout protocol_version_no;
    flush cout;
    let opponent_version_no = read_line() in
    if protocol_version_no = opponent_version_no then begin
        print_endline "Protocol match, handshake success.";
        true    
    end
    else begin
        printf "Error: protocol version %s not match" opponent_version_no;
        flush stdout;
        false
    end*)

let wait_to_send vagent msg = 
    Mutex.lock vagent.sending_mutex;
    Queue.push msg vagent.sending_queue;
    Condition.signal vagent.sending_conditional;
    Mutex.unlock vagent.sending_mutex

let create_session vagent (session: session) = wait_to_send vagent (Create_session (session.name, (str_proof_kind session.kind) ^" "^session.name, "Tree", node_state_list))
let remove_session vagent sid = wait_to_send vagent (Remove_session sid)
let add_node vagent sid node = wait_to_send vagent (Add_node (sid, node))
let remove_node vagent sid nid = wait_to_send vagent (Remove_node (sid, nid))
let add_edge vagent sid from_id to_id label = wait_to_send vagent (Add_edge (sid, from_id, to_id, label))
let remove_edge vagent sid from_id to_id = wait_to_send vagent (Remove_edge (sid, from_id, to_id))
let change_node_state vagent sid nid state = wait_to_send vagent (Change_node_state (sid, nid, state))
let highlight_node vagent sid nid = wait_to_send vagent (Highlight_node (sid, nid))
let unhighlight_node vagent sid nid = wait_to_send vagent (Unhighlight_node (sid, nid))
let feedback_ok vagent sid = wait_to_send vagent (Feedback_ok sid)
let feedback_fail vagent sid error_msg = wait_to_send vagent (Feedback_fail (sid, error_msg))


let json_of_msg (msg:message) = 
    match msg with
    | Create_session (session_id, session_descr, graph_type, node_state_list) ->
        `Assoc [
            ("type", `String "create_session");
            ("session_id", `String session_id);
            ("session_descr", `String session_descr);
            ("graph_type", `String graph_type);
            ("node_states", `List (List.map (fun a -> `String (str_node_state a)) node_state_list))
        ]
    | Remove_session sid ->
        `Assoc [
            ("type", `String "remove_session");
            ("session_id", `String sid)
        ]
    | Add_node (sid, node) ->
        `Assoc [
            ("type", `String "add_node");
            ("session_id", `String sid);
            ("node", `Assoc [
                ("id", `String node.id);
                ("label", `String (str_label node.label));
                ("state", `String (str_node_state node.state))
            ])
        ]
    | Remove_node (sid, nid) ->
        `Assoc [
            ("type", `String "remove_node");
            ("session_id", `String sid);
            ("node_id", `String nid)
        ]
    | Add_edge (sid, from_id, to_id, label) ->
        `Assoc [
            ("type", `String "add_edge");
            ("session_id", `String sid);
            ("from_id", `String from_id);
            ("to_id", `String to_id);
            ("label", `String label)
        ]
    | Remove_edge (sid, from_id, to_id) ->
        `Assoc [
            ("type", `String "remove_edge");
            ("session_id", `String sid);
            ("from_id", `String from_id);
            ("to_id", `String to_id)
        ]
    | Change_node_state (sid, nid, new_state) ->
        `Assoc [
            ("type", `String "change_node_state");
            ("session_id", `String sid);
            ("node_id", `String nid);
            ("new_state", `String (str_node_state new_state))
        ]
    | Highlight_node (sid, nid) ->
        `Assoc [
            ("type", `String "highlight_node");
            ("session_id", `String sid);
            ("node_id", `String nid)
        ]
    | Unhighlight_node (sid, nid) ->
        `Assoc [
            ("type", `String "unhighlight_node");
            ("session_id", `String sid);
            ("node_id", `String nid)
        ]
    | Feedback_ok sid ->
        `Assoc [
            ("type", `String "feedback");
            ("session_id", `String sid);
            ("status", `String "OK")
        ]
    | Feedback_fail (sid, error_msg) ->
        `Assoc [
            ("type", `String "feedback");
            ("session_id", `String sid);
            ("status", `String "Fail");
            ("error_msg", `String error_msg)
        ]

let rec get_json_of_key key str_json_list = 
    match str_json_list with
    | (str, json) :: str_json_list' -> 
        if str = key then
            json
        else 
            get_json_of_key key str_json_list'
    | [] -> printf "not find json for key %s\n" key; exit 1 


let get_string_of_json json = 
    match json with
    | `String str -> str
    | _ -> printf "%s is not a string\n" (Yojson.Basic.to_string json); exit 1


let msg_of_json json = 
    match json with
    | `Assoc str_json_list -> begin
            match get_string_of_json (get_json_of_key "type" str_json_list) with
            | "highlight_node" -> 
                Highlight_node ((get_string_of_json (get_json_of_key "session_id" str_json_list)), (get_string_of_json (get_json_of_key "node_id" str_json_list)))
                (*printf "highlight node %s in session %s\n" (get_string_of_json (get_json_of_key "node_id" str_json_list)) (get_string_of_json (get_json_of_key "session_id" str_json_list));
                flush stdout*)
            | "feedback" -> 
                let status = get_string_of_json (get_json_of_key "status" str_json_list) in
                if status = "OK" then
                    Feedback_ok (get_string_of_json (get_json_of_key "session_id" str_json_list))
                    (*printf "OK from session %s\n" (get_string_of_json (get_json_of_key "session_id" str_json_list))*)
                else
                    Feedback_fail ((get_string_of_json (get_json_of_key "session_id" str_json_list)), (get_string_of_json (get_json_of_key "error_msg" str_json_list)))
                    (*printf "Fail from session %s: %s\n" (get_string_of_json (get_json_of_key "session_id" str_json_list)) (get_string_of_json (get_json_of_key "error_msg" str_json_list));*)
                (*flush stdout*)
            | _ as s -> printf "not supposed to be received by coqv: %s\n" s; exit 1
        end
    | _ -> printf "%s can not be a message\n" (Yojson.Basic.to_string json); exit 1

let sending vagent =
    let cout = vagent.output in
    (*let running = ref true in*)
    let log_out = open_out log_file in
    while vagent.is_alive do
        if Queue.is_empty vagent.sending_queue then begin
            Mutex.lock vagent.sending_mutex;
            Condition.wait vagent.sending_conditional vagent.sending_mutex;
            Mutex.unlock vagent.sending_mutex
        end else begin
            let msg = ref (Feedback_ok "") in
            Mutex.lock vagent.sending_mutex;
            msg := Queue.pop vagent.sending_queue;
            Mutex.unlock vagent.sending_mutex;
            (*begin
                match !msg with
                | Terminate -> running := false
                | _ -> ()
            end;*)
            let json_msg = json_of_msg !msg in
            (*Yojson.Basic.to_channel cout json_msg;*)
            output_string cout ((Yojson.Basic.to_string json_msg)^"\n");
            flush cout;
            output_string log_out "JSON data sent:\n";
            output_string log_out (Yojson.Basic.to_string json_msg);
            output_string log_out "\n";
            flush log_out
        end
    done

let parse vagent msg = 
    match msg with
    | Highlight_node (sid, nid) -> 
        printf "Highlight node %s in session %s\n" nid sid;
        flush stdout;
        feedback_ok vagent sid
    | Unhighlight_node (sid, nid) ->
        printf "Unhighlight node %s in session %s\n" nid sid;
        flush stdout;
        feedback_ok vagent sid
    | Feedback_ok sid ->
        printf "Feedback OK received from %s\n" sid;
        flush stdout
    | Feedback_fail (sid, error_msg) ->
        printf "Feedback Fail received from %s: %s\n" sid error_msg;
        flush stdout
    | _ -> 
        printf "Not supposed to recieve this message\n";
        flush stdout

let receiving vagent =
    let cin = vagent.input in 
    (*let running = ref true in*)
    let log_out = open_out log_file in
    while vagent.is_alive do
        let json_msg = Yojson.Basic.from_channel cin in
        output_string log_out "JSON data received:\n";
        output_string log_out (Yojson.Basic.to_string json_msg);
        output_string log_out "\n";
        flush log_out;
        let msg = msg_of_json json_msg in
        parse vagent msg
    done

let start_send_receive vagent =
    ignore (Thread.create (fun vagent -> receiving vagent) vagent);
    ignore (Thread.create (fun vagent -> sending vagent) vagent)

let get_visualize_agent ip_addr = 
    let i,o = Unix.open_connection (Unix.ADDR_INET (Unix.inet_addr_of_string ip_addr, 3333)) in
    let vagent: visualize_agent = {
        input = i;
        output = o;
        is_alive = true;
        sending_queue = Queue.create ();
        sending_mutex = Mutex.create ();
        sending_conditional = Condition.create ()
    } in
    start_send_receive vagent;
    vagent



