(* This file is part of cqpl, a communication-capable quantum
   programming language.
   Copyright (C) 2005, Wolfgang Mauerer <wm@linux-kernel.net>

   This program is free software; you can redistribute it and/or
   modify it under the terms of the GNU General Public License
   as published by the Free Software Foundation; either version 2
   of the License, or (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with cqpl.  If not, see <http://www.gnu.org/licenses/>. *)

(* Code generation for the qcl backend *)

open Helpers
open Parser_defs
open Exceptions
open Type

(* Transform the previous results in tree to a c++ file (filename given
   by output *)
let rec gen_qcl_code qheap_size module_list oc =
  write_prologue qheap_size module_list oc;
  perform_conversion module_list oc;
  write_epilogue module_list oc;


and write_prologue qheap_size module_list oc =
  let module_names = List.map (fun x -> x.mod_name) module_list in
  writeln oc "/* This file was generated by the qcl backend of qpl, do not";
  writeln oc "   modify it by hand - all changes will be lost! */";
  writeln oc "";
  writeln oc "#include <iostream>";
  writeln oc "#include <string>";
  writeln oc "#include \"operator.h\"";
  writeln oc "#include \"qustates.h\"";
  writeln oc "#include \"format.h\"";
  writeln oc "#include \"qpl_runtime.h\"";
  writeln oc "#include \"qpl_runtime_comm.h\"";
  writeln oc "";                  
  writeln oc ("quBaseState local_mem(" ^ (string_of_int qheap_size) ^ ");");
  writeln oc "unsigned long qMemPos = 0;";
(*  writeln oc "pthread_mutex_t quant_lock = PTHREAD_MUTEX_INITIALIZER;"; *)
  writeln oc "pthread_mutex_t memory_lock = PTHREAD_MUTEX_INITIALIZER;";
  let channel_names = gen_channel_names module_names in
  List.iter (fun channel -> 
    writeln oc ("queue<comm_t> *data_queue_" ^ channel ^ 
		" = new queue<comm_t>;");
    writeln oc ("pthread_cond_t queue_cond_" ^ channel ^ ";");
    writeln oc ("pthread_mutex_t cond_lock_" ^ channel ^ ";");
    writeln oc ("pthread_mutex_t queue_lock_" ^ channel ^ ";"))
    channel_names;
  writeln oc "";

and write_epilogue module_list oc =
  let num_modules = List.length module_list in
  writeln oc "int main(int argc, char** argv) {";
  writeln oc "runtime_init();";
  writeln oc ("pthread_t tids[" ^ string_of_int num_modules ^ "];");
  writeln oc "";
  
  (* Generate code to start all threads *)
  let num = ref 0 in
  List.iter (fun x -> writeln oc ("create_thread(&tids[" ^ 
				  (string_of_int !num) ^ "], " ^ 
				  x.mod_name ^ ", \"" ^ x.mod_name ^ "\");");
	    num := !num + 1) 
    module_list;
  writeln oc "";

  (* Generate the code to wait for all threads to finish *)
  writeln oc ("for (int count = 0; count < " ^ (string_of_int num_modules) 
	      ^ "; count++) {");
  writeln oc "    int err;";
  writeln oc "    if (err = pthread_join(tids[count], NULL)) {";
  writeln oc "        cerr << \"Runtime error: pthread_join\" << endl;";
  writeln oc "        exit (-1);";
  writeln oc "     }";
  writeln oc "}"; (* End of the for loop *)
  writeln oc "}"; (* End of main *)
  writeln oc "/* End of generated code */"
  

(* TODO: Make paths etc. configurable *)
and compile_qcl_code tmpfile outfile =
  print_line "Compiling QCL output to native code.";
  let cmd_line = 
    ("c++ -g -I ../qcl-0.6.1/ -I . -I ../qcl-0.6.1/qc qpl_runtime.o " ^
     "qpl_runtime_comm.o -lpthread " ^ tmpfile ^ 
     " ../qcl-0.6.1/qc/libqc.a -o " ^ outfile) in
  debug ("command line: " ^ cmd_line);
  let ret_code = Sys.command cmd_line in
  if (ret_code = 0) then 
    print_line "Native compilation finished."
  else 
    internal_error ("Native code compilation failed with error code " ^ 
		    (string_of_int ret_code));

(* *********************************************************************** *)
(* ***                     Main conversion routines                    *** *)
(* *********************************************************************** *)
and perform_conversion module_list oc =
  List.iter (fun x -> perform_stmt_conversion x.mod_name x.mod_stmt_list oc) 
    module_list 

and perform_stmt_conversion mod_name stmt_list oc =
  (* Generate forward declarations for all procedures which
     cross our way. *)
   let proc_list = create_proc_list stmt_list in
   begin List.iter (fun p -> match p with Proc_decl (p_decl, p_annot) ->
              begin 
                write oc ("qplReturnContext " ^ p_decl.proc_name ^ 
                          "(qplCallContext&");
                begin 
                  let type_list = list_tuple_second p_decl.proc_in_context in
                  let class_type_list = get_classical_types type_list in
                  List.iter (fun var_type -> 
                                 write oc (", " ^ (gen_native_type var_type )))
                            class_type_list   
                end;
                writeln oc ");";
              end
            (* This is the general case for fun p -> ... *)
            | _ -> internal_error "Non-proc element in proc_list!") 
         proc_list (* We iterate over this list with fun p -> ... *)
   end;

  (* Then, generate the toplevel code for the module that is not contained in a
     qpl procedure and will reside in module() where module denotes
     the module name. Skip all procedure
     declarations and process only the rest. *)
  let num_qbits = get_required_qbits stmt_list in
  (* The main procedure needs to return a value to the operating
     system and does therefore not adhere to the qpl calling and
     return conventions because we need to interact with the real
     world somehow (unfortunately...) *)
  writeln oc "";
  writeln oc ("void* " ^ mod_name ^ "(void *arg) {");
(*   writeln oc ("quBaseState local_mem(" ^ (string_of_int num_qbits) ^ ");");
   writeln oc "unsigned long qMemPos = 0;"; *)
  writeln oc ("/* Good to know: This block requires " ^ 
	      (string_of_int num_qbits) ^ " qbits. */");
  writeln oc "qplReturnContext retContext;";
  writeln oc "qplCallContext callContext;";
  writeln oc "comm_t recv;";
  writeln oc "comm_t send;";
  
  (* Create a list of executable statements, i.e. all statements
     that are not procedures and all statements that are within 
     procedure scopes. These are packed together in the main routine *)
  let exec_stmt_list = create_exec_stmt_list stmt_list in
  List.iter (gen_stmt_code oc) exec_stmt_list;
  
  writeln oc "}"; (* Close the main procedure *)
  
  (* Then, generate code for the procedures *)
  List.iter (gen_stmt_code oc) proc_list 
    
    
(* Extract all statements that are suitable for the main procedure *)
and create_exec_stmt_list stmt_list =
  match stmt_list with 
    x::xs -> begin
      match x with
        Proc_decl (p, annot) -> 
	  List.append (create_exec_stmt_list [p.proc_scope])
            (create_exec_stmt_list xs)
      | _ -> x::(create_exec_stmt_list xs)
    end
  | [] -> []
	
	
(* Equivalently, extract all procedure declarations *)
and create_proc_list stmt_list =
  match stmt_list with
    x::xs -> begin
      match x with
        Proc_decl (p, annot) -> x::(create_proc_list xs)
      | _ -> create_proc_list xs
    end
  | [] -> []
	
	
(* Generate the head code for a procedure called "name" with the
   given arguments and return values, allocating num_qbits qbits *)
and gen_proc_head oc name return_spec param_spec num_qbits =
  write oc ("qplReturnContext " ^ name ^ " (" ^ "qplCallContext &__" ^ 
	       name ^ "__inContext");
  List.iter (fun (var_name, var_type) -> 
               write oc (", " ^ (gen_native_type var_type)  ^ " " ^ var_name)) 
            (get_classical_tuples param_spec);
  writeln oc ") {";
  writeln oc "qplReturnContext retContext;";
  writeln oc "qplCallContext callContext;";
  writeln oc "comm_t recv;";
  writeln oc "comm_t send;";
  create_in_context oc name param_spec;
(*  if (num_qbits = 0) then ()
  else writeln oc ("quBaseState local_mem (" ^ (string_of_int num_qbits)
		   ^ ");");
  writeln oc "unsigned long qMemPos = 0;"*)
  
  
(* Create local variables for a procedure and store the information from
   the incoming context *)
and create_in_context oc prefix param_spec =
  List.iter 
    (fun (name, var_type) -> 
         if (quantum_type var_type) then begin
         writeln oc ((gen_native_type var_type) ^ " *" ^ name ^ " = (" ^ 
		     (gen_native_type var_type) ^ "*) __" ^ prefix ^ 
		     "__inContext.get(\"" ^ name ^ "\");") end)
    param_spec;
    

(* Find the corresponding C++ type for a given QPL type *)
and gen_native_type var_type =
   match var_type with
     Qbit_type  -> "quBit";
   | Qint_type  -> "quInt";
   | Bit_type   -> "bit";
   | Int_type   -> "int";
   | Float_type -> "float";
   | Proc_type(x,y) -> 
       internal_error "Procedures are not first-class elements!"


(* Generate a new instance of qplReturnContext, fill and return it. *)
(* Note: Don't confuse retContext (which is used passively to
   receive parameters returned from a procedure call) and
   retValueContext (which is set up actively to pass variables
   to the calling procedure) *)
and gen_proc_tail oc s annot =
   writeln oc "qplReturnContext *retValueContext = new qplReturnContext();";
   let classical_tuples = get_classical_tuples s.proc_in_context in
   List.iter (fun (var_name, var_type) -> 
                writeln oc ("retValueContext->set_" ^ 
			    (gen_native_type var_type) ^ 
                            "(\"" ^ var_name  ^ "\", " ^ var_name ^ ");")) 
             classical_tuples;
   writeln oc "return *retValueContext;";
   writeln oc "}";
    
    
(* Scan all statements in the list and compute how many qbits need
   to be allocated in the current activation record (ie. block) *)
and get_required_qbits stmt_list =
  match stmt_list with
    x::xs -> begin let temp = 
      (match x with 
	Allocate_stmt (s, annot) -> 
	  get_required_qbits_primitive s.allocate_type
      | _ -> 0)
    in temp + (get_required_qbits xs)
    end
  | [] -> 0
	
	
and gen_stmt_code oc stmt =
  match stmt with
    Measure_stmt (s,annot)  -> gen_code_measure_stmt oc s annot
  | Allocate_stmt (s,annot) -> gen_code_allocate_stmt oc s annot
  | Proc_call (s,annot)     -> gen_code_proc_call oc s annot
  | While_stmt (s,annot)    -> gen_code_while_stmt oc s annot
  | If_stmt (s,annot)       -> gen_code_if_stmt oc s annot
  | Skip_stmt               -> gen_code_skip_stmt oc 
  | Gate_stmt (s,annot)     -> gen_code_gate_stmt oc s annot
  | Block (s,annot)         -> gen_code_block oc s annot
  | Proc_decl (s,annot)     -> gen_code_proc_decl oc s annot
  | Assign_stmt (s,annot)   -> gen_code_assign_stmt oc s annot
  | Assign_measure_stmt (s,annot)   -> gen_code_assign_measure_stmt oc s annot
  | Print_stmt (s,annot)    -> gen_code_print_stmt oc s annot
  | Send_stmt (s,annot)     -> gen_code_send_stmt oc s annot
  | Receive_stmt (s,annot)  -> gen_code_receive_stmt oc s annot


and gen_code_skip_stmt oc = 
  writeln oc "{ /* Skip */ }";


(* Extract the desired information from the ast node and
   delegate the real work to gen_proc_head.
   Prototype is gen_proc_head oc name return_spec param_spec num_qbits 
   Afterwards, generate the procedure statements *)
and gen_code_proc_decl oc s annot =
  match s.proc_stmts with (p_stmts, p_annot) -> begin
    gen_proc_head oc s.proc_name s.proc_out_context s.proc_in_context 
      (get_required_qbits p_stmts);
    
    let exec_stmt_list = create_exec_stmt_list p_stmts in
    List.iter (gen_stmt_code oc) exec_stmt_list;
    
    gen_proc_tail oc s annot;
  end

and gen_code_measure_stmt oc s annot =
  let measure_stmt = s.measure_var ^ "->get()" in
  let var_cast = gen_cast_stmt measure_stmt annot#get_dest_type_list in 
  writeln oc ("if (" ^ var_cast  ^ ")");
  gen_stmt_code oc s.measure_then_stmt;
  writeln oc "else";
  gen_stmt_code oc s.measure_else_stmt


(* Set up a qpl context and call the procedure. The call context
   is nothing else than a hashtable (or, as the STL calls it, a Map)
   which associates variable names with references to the respective
   simulation variables if they are quantum data types or
   values if they are classical types. *)
and gen_code_proc_call oc s annot =
  writeln oc "callContext.reset();";
  (* Create a list which associates the names of the local quantum variables
     with the names the called procedure expects them to have *)
  let comb_list = List.combine s.proc_call_args !(s.proc_call_var_trans) in

  (* Only add quantum variables to the call context; everything
     else is passed as regular procedure parameter *)
  (* First, extract the names of the local classical variables which
     are used as procedure parameters. In (e,f) = X(a,b,c), this would
     be eg. ["a","b"] if they are the classical types. *)
  let classic_caller_vars = 
                    list_tuple_first !(s.proc_call_classic_caller_tuples) in
  (* Then, construct a proper input context with all quantum variables *)
  List.iter 
    (fun (local_var_name, remote_name) -> 
      if (not(list_contains local_var_name classic_caller_vars)) then
      writeln oc ("callContext.set(\"" ^ remote_name  ^ "\", " ^ 
		  local_var_name ^ ");")) 
    comb_list;

  (* Issue the procedure call with the call context for the quantum 
     variables and the classical variables as explicit call-by-value
     parameters. *)
  write oc ("retContext = " ^ s.proc_call_called ^ 
            "(callContext");
  List.iter (fun x -> write oc (", " ^ x)) classic_caller_vars;
  writeln oc ");";

  (* Store the classical results into the proper variables unless the result
     is completely voided. Appropriate naming changes and typecasts have to 
     take place. Since C++ doesn't allow multiple return variables,
     we have to embed them into a special return context and revover
     them from there. *)
  if (List.length s.proc_call_out != 0) then begin
    (* TODO: Typecasting between the returned and the actually used
       datatype *)
    List.iter2 (fun local_name (remote_name, remote_type) -> 
                    writeln oc (local_name ^ " = retContext.get_" ^ 
                                 (gen_native_type remote_type) ^ "(\"" ^
                                 remote_name ^ "\");"))
               s.proc_call_out !(s.proc_call_classic_callee_vars)
  end;


and gen_code_assign_stmt oc s annot =
  (* TODO: This needs further work, eg. typecasting *)
  writeln oc (s.assign_var ^ " = " ^ 
	   (gen_arith_expression_string s.assign_expr) ^ ";");


(* TODO: This needs to be implemented properly (e.g, with proper 
   typecasting)! *)
and gen_code_assign_measure_stmt oc s annot =
  writeln oc (s.assign_meas_dest ^ " = " ^ s.assign_meas_var ^ 
	      "->measure().getword();");


and gen_code_while_stmt oc s annot =
  (* TODO: Implement proper typecasting *)
  writeln oc ("while(" ^ 
	    (gen_arith_expression_string s.while_condition) ^ ") {");
  gen_stmt_code oc s.while_stmt;
  writeln oc "}";


(* TODO: For now, we bruta force assume that this is a qbit *)
and gen_code_send_stmt oc s annot =
  let channel_name = (gen_channel_name s.send_to annot#get_module_name) in
  List.iter (fun x -> 
    let sent_type = (List.nth annot#get_dest_type_list 0) in
    begin 
      (match sent_type with
	Bit_type ->
	  writeln oc "send.dtype = BIT;";
	  writeln oc ("send.value.b = " ^ x ^ ";");
      | Int_type ->
	  writeln oc "send.dtype = INT;";
	  writeln oc ("send.value.i = " ^ x ^ ";");
      | Float_type ->
	  writeln oc "send.dtype = FLOAT;";
	  writeln oc ("send.value.f = " ^ x ^ ";");
      | Qbit_type -> 
	  writeln oc "send.dtype = QBIT;";
	  writeln oc ("send.value.ptr = " ^ x ^ ";");
      | Qint_type ->
	  writeln oc "send.dtype = QINT;";
	  writeln oc ("send.value.ptr = " ^ x ^ ";");
      | _ -> internal_error "This type is not supposed to be sent!");
      
      (* Generating the send command with appropriate locking
	 is identical for all cases *)
      writeln oc ("send_data(send, data_queue_" ^ channel_name ^ 
		  ", &queue_cond_" ^ channel_name ^ ", " ^ 
		  "&cond_lock_" ^ channel_name ^ 
		  ", &queue_lock_" ^ channel_name ^ ");");
      writeln oc "";
    end) s.send_vars;


and gen_code_receive_stmt oc s annot =
  let channel_name = gen_channel_name s.receive_from annot#get_module_name in
   List.iter (fun x ->
     match x with (var_name, var_type) ->
       begin
	 let native_type = (gen_native_type var_type) in 
	 let backend_signature = (var_type_to_backhand_signature var_type) in 
	 writeln oc ("recv = get_data(data_queue_" ^ channel_name ^ 
		     ", &queue_cond_" ^ channel_name ^ 
		     ", &cond_lock_" ^ channel_name ^ ", " ^ 
		     "&queue_lock_" ^ channel_name ^ ");");
	 (match var_type with
	   Bit_type | Int_type | Float_type ->
	     writeln oc (native_type ^ " " ^ var_name ^ " = (" ^ 
			 native_type ^ ") recv.value." ^ 
			 var_type_to_backend_shorthand var_type ^ ";";)
	 | Qbit_type | Qint_type -> 
	     writeln oc (native_type ^ " *" ^ var_name ^ " = (" ^ 
			 native_type ^ "*) recv.value.ptr;";)
	 | Proc_type (_,_) -> 
	     internal_error "Proc types should not appear here!");
	 (* Check (in the generated code) if the received data type 
	    matches the expected one *)
	 writeln oc ("if (recv.dtype != " ^ backend_signature ^ ") {"); 
	 writeln oc ("cerr << \"Internal error: Received wrong data " ^
		     "type\" << endl;");
	 writeln oc "exit(-1); }";
       end) s.receive_vars;

and gen_code_if_stmt oc s annot =
  (* TODO: Typecasting and stuff *)
  write oc "if (";
  gen_arith_expression oc s.if_condition;
  writeln oc ")";
  gen_stmt_code oc s.if_then_stmt;
  gen_stmt_code oc s.if_else_stmt


and gen_code_gate_stmt oc s annot =
  (* First, construct a quantum state of all variables involved *)
  let gate_var = List.fold_left (fun str1 str2 -> (str1 ^ str2)) 
                                "" s.gate_vars in
  let applic_var = (if ((List.length s.gate_vars) > 1) then
    ("(new quCombState(" ^ gen_combination_statement s.gate_vars ^ "))")
  else (gate_var)) in

  (* Then, apply the proper gate *)
  match s.gate_operator with
    Hadamard_gate      -> writeln oc ("ophadamard->apply(*" ^ applic_var^ ");")
  | CNot_gate          -> writeln oc ("opcnot->apply(*" ^ applic_var  ^ ");")
  | Not_gate           -> writeln oc ("opnot->apply(*" ^ applic_var  ^ ");")
  | Phase_gate phase   -> 
      writeln oc ("(new opCPhase(1, " ^ (string_of_float phase) ^ 
		  "))->apply(*" ^ applic_var  ^ ");")
  | Fourier_gate dim -> writeln oc ("opFFT(" ^ (string_of_int dim) ^ ")(*" ^
                                    applic_var ^ ");")
  | User_gate num_list -> 
      let l_string = (string_of_int (List.length num_list)) in 
      writeln oc ("userOperator(" ^ l_string ^ "," ^
		  "create_array<complx>("  ^ l_string ^ ", " ^ 
		  (list_commify (List.map (fun x -> ("new complx(" ^ 
				      (string_tuple_of_complex x) ^ ")"))
                                           num_list)) ^ 
		  "))->apply(*" ^ applic_var  ^ ");") 
	

and gen_code_block oc s annot =
  writeln oc "{ ";
  let num_qbits = get_required_qbits s in
  if (num_qbits != 0) then 
    begin
      writeln oc ("/* Info: this block requires " ^ (string_of_int num_qbits) ^
		  " qbits */");
(*   writeln oc ("quBaseState local_mem(" ^ (string_of_int num_qbits) ^ ");");
   writeln oc "unsigned long qMemPos = 0;";*)
    end;
  List.iter (gen_stmt_code oc) s;
  writeln oc "}";


and gen_code_print_stmt oc s annot =
  let module_name = annot#get_module_name in
  match s with
    Print_string str -> writeln oc ("cout << \"[" ^ module_name ^
				    "] " ^ str ^ "\" << endl;");
  | Print_arith_expression e -> 
      write oc ("cout << \"[" ^ module_name ^ "]\" << ");
      write oc (gen_cast_expression e annot#get_dest_type_list);
      writeln oc " << endl;";
  | Print_quantum_value qv -> 
      begin
	writeln oc ("cout << \"[" ^ module_name ^ "] \";");
	if (List.length qv > 1) then 
          writeln oc ("dump_quantum_value(new quCombState(" ^ 
		      gen_combination_statement qv ^ "), &cout);")
	else writeln oc ("dump_quantum_value(" ^ (List.nth qv 0)  ^ 
			 ", &cout);")
      end;

and gen_code_allocate_stmt oc s annot =
   (* Allocate quantum variables from the local quantum heap; let the 
      backend do the same for classical variables.
      Real quantum memory management (ie. assigning absolute positions 
      to the variables in the local or global heap) is done by the backend;
      we rely on the backend's capability to select a subset of a given
      size at the start of a procedure which we view as a linear chain
      of quantum bits. *)
  match s.allocate_value with (allocate_value, value_annotation) ->
    let q_alloc_type = (gen_native_type s.allocate_type) in
    match (quantum_type s.allocate_type) with
      true  -> begin
	writeln oc (q_alloc_type ^ " *" ^ s.allocate_var ^ 
         " = allocateMem<" ^ q_alloc_type ^ ">(" ^ 
        (string_of_int (get_required_qbits_primitive s.allocate_type)) ^ ");");
	
	(* In order to set a variable to some value, we use the 
	   function assignValue from the runtime library which
	   constructs a proper sequence of Not and 1-gates to
	   set the contributing qbits to the required states *)
        writeln oc ("assignValue(" ^ 
              (gen_arith_expression_string allocate_value) ^ ", " ^
               (string_of_int (get_required_qbits_primitive s.allocate_type)) 
               ^ ")(*" ^ s.allocate_var ^ ");"); 
      end
    | false -> begin
        writeln oc ((gen_native_type s.allocate_type) ^ " " ^ 
		    s.allocate_var ^ ";");
	write oc (s.allocate_var ^ " = ");
	write oc (gen_cast_expression allocate_value 
                                      value_annotation#get_dest_type_list);
	writeln oc ";"
    end
	  
	  
(* Generate the code for an arithmetic expression to oc *)
and gen_arith_expression oc arith_expr =
  writeln oc (gen_arith_expression_string arith_expr)
    

(* Generate an arithmetic expression together with the approprate
   type conversions for the fundamental components *)
and gen_arith_expression_string arith_expr =
  match arith_expr with
    (* TODO: Typecast direct values to the type of the whole expression *)
    Float_value (v, annot) -> gen_cast_stmt (string_of_float v) 
                                            annot#get_dest_type_list
  | Int_value (i, annot)   -> gen_cast_stmt (string_of_int i)
                                             annot#get_dest_type_list
  | Variable (var, annot)  -> gen_cast_stmt var annot#get_dest_type_list
  | True -> "true"
  | False -> "false"
  | Negated_expression sub_expr -> 
      "-1 * (" ^ (gen_arith_expression_string sub_expr) ^  ")"
  | Comp_Node  (op, lhs, rhs) -> 
      "static_cast<bool>(" ^ (gen_arith_expression_string lhs) ^ 
      (gen_cmp_operator_string op) ^ (gen_arith_expression_string rhs) ^ ")"
  | Arith_Node (op, lhs, rhs) -> 
      (* Note that the complete expression has the correct type
	 automatically because all subexpressions have been casted to 
	 the proper type already *)
      (gen_arith_expression_string lhs) ^ (gen_arith_operator_string op) ^ 
      (gen_arith_expression_string rhs) 
  | User_type -> internal_error "User types are not yet implemented!"


(* Generate the different types of operators *)
and gen_cmp_operator oc operator =
  writeln oc (gen_cmp_operator_string operator)

and gen_cmp_operator_string operator =
  match operator with
    Greater -> ">"
  | Less -> "<"
  | Greater_eq -> ">="
  | Less_eq -> "<="
  | Equals -> "=="
  | Not_equals -> "!="
  | And -> "&&"
  | Or -> "||"


and gen_arith_operator oc operator =
  writeln oc (gen_arith_operator_string operator)

and gen_arith_operator_string operator =
  match operator with
    Plus_op -> "+"
  | Minus_op -> "-"
  | Times_op -> "*"
  | Div_op -> "/"


(* Generate code for the creation of a quantum state where
   all quantum variables in var_list are appended to a single combined state *)
(* Note: This assumes that the list has at least 2 elements. Since this
   condition can always be checked by the calling function, we don't
   perform the check here because this allows greater flexibility for
   the caller *)
and gen_combination_statement var_list =
  match var_list with
    x::xs -> begin 
      if ((List.length var_list) > 2) then begin 
	"*" ^ x ^ ", quCombState(" ^ (gen_combination_statement xs) ^ ")"
      end 
      else begin
	"*" ^ x ^ ", *" ^ List.nth xs 0
      end
    end
  | [] -> ""


(* Convert an internal classical data type (e.g Int_type to the shorthand
   used in the union for communication transmission *)
and var_type_to_backend_shorthand var_type =
  match var_type with
    Bit_type -> "b"
  | Int_type -> "i"
  | Float_type -> "f"
  | Qbit_type | Qint_type | Proc_type (_,_) -> 
      internal_error ("Shorthand for quantum/procedure " ^ 
		      "types should not be necessary!")
	

(* Generate the backend signature (used as a check in the transmission
   structure) for a data type *)
and var_type_to_backhand_signature var_type =
  match var_type with
    Bit_type -> "BIT";
  | Int_type -> "INT";
  | Float_type -> "FLOAT";
  | Qbit_type -> "QBIT";
  | Qint_type -> "QINT";
  | Proc_type (_,_) -> internal_error ("Signatures for procedure types " ^ 
				       "should not be necessary!")

	
(* Generate a cast statement for variable var by returning the appropriate
   c++ code string *)
and gen_cast_stmt var cast_list =
  match cast_list with
    x::xs -> "static_cast<" ^ (gen_native_type x) ^ ">(" ^
      (gen_cast_stmt var xs) ^ ")"
  | [] -> var


(* The same thing for an arithmetic expression *)
and gen_cast_expression expr cast_list =
  match cast_list with
    x::xs -> "static_cast<" ^ (gen_native_type x) ^ ">(" ^
      (gen_cast_expression expr xs) ^ ")"
  | [] -> gen_arith_expression_string expr
	

(* Create a unique channel name from the names of two communicating
   modules *)
and gen_channel_name mod1 mod2 =
  if ((String.compare mod1 mod2) <= 0) then
    (mod1 ^ "_" ^ mod2)
  else (mod2 ^ "_" ^ mod1)

and gen_channel_names module_names =
  let modules_pairs = list_gen_pairs module_names in
  List.map (fun x -> match x with (a,b) -> gen_channel_name a b) modules_pairs
