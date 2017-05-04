open Printf
open Str
open Runtime
open Handle_interaction

let in_chan = stdin
let out_chan = stdout
let running = ref true

let command_re = Str.regexp ":[-_A-Za-z0-9]+"

let read_write_condition = Condition.create ()
let read_write_mutex = Mutex.create ()

let worker cin =     
    let buffer = Bytes.create 4096 in
    while !running do
        let len = input cin buffer 0 4096 in
        if len = 0 then
            running := false
        else begin
            let output_str = Bytes.sub_string buffer 0 len in
            (*printf "%s" (Str.global_replace (ignored_re ()) "" output_str);
            flush stdout*)
            if(len <> 0) then
                handle_feedback output_str
        end;
        Condition.signal read_write_condition
    done

let rec loop args = 
    let master2slave_in, master2slave_out = Unix.pipe () 
    and slave2master_in, slave2master_out = Unix.pipe () in
    Unix.set_close_on_exec master2slave_out;
    Unix.set_close_on_exec slave2master_in;
    (*let pid = Unix.create_process "/usr/bin/coqtop" (Array.of_list args)  master2slave_in slave2master_out slave2master_out in*)
    let pid = Unix.create_process "coqtop" (Array.of_list args)  master2slave_in slave2master_out slave2master_out in
    if pid = 0 then 
        printf "create process error"
    else begin
        (*printf "created process %d\n" pid;*)
        let cin, cout = Unix.in_channel_of_descr slave2master_in, Unix.out_channel_of_descr master2slave_out in
        Unix.close master2slave_in;
        Unix.close slave2master_out;
        (*starting reading from repl*)
        (*In_thread.run (fun () -> worker cin);*)
        ignore(Thread.create worker cin);
        (*input header information*)
        let buffer = Bytes.create 1024 in
        let len = input cin buffer 0 1024 in
        let header = Bytes.sub_string buffer 0 len in
        printf "\t\tCoqV version 0.1 [coqtop version %s]\n\n" (Str.global_replace (Str.regexp "\n") "" (Str.global_replace (Str.regexp "Welcome to Coq ") "" header));
        let running_coqv = ref false in
        while !running do
            if not !running_coqv then begin
                Mutex.lock read_write_mutex;
                Condition.wait read_write_condition read_write_mutex;
                Mutex.unlock read_write_mutex;
                Thread.delay 0.01
            end;
            print_string "coqv> ";
            let input_str = read_line () in
            (*printf "input length: %d\n" (String.length input_str);*)
            if (String.length input_str > 0) then begin
                if String.sub input_str 0 1 = ":" then begin
                    running_coqv := true;
                    let cmd = (String.sub input_str 1 (String.length input_str - 1)) in
                    (*printf "command name: %s\n" cmd;
                    flush stdout*)
                    interpret_cmd cmd
                end else begin
                    running_coqv := false;
                    handle_input input_str cout
                end
            end else 
                running_coqv := true
        done
    end

let _ = loop ["-ideslave"]