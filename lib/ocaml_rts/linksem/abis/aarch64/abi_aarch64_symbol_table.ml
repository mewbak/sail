(*Generated by Lem from abis/aarch64/abi_aarch64_symbol_table.lem.*)
(** [abi_aarch64_symbol_table], symbol table specific defintions for the AARCH64
  * ABI.
  *)

open Lem_basic_classes
open Lem_bool

open Elf_header
open Elf_symbol_table
open Elf_section_header_table
open Elf_types_native_uint

(** Two types of weak symbol are defined in the AARCH64 ABI.  See Section 4.5.
  *)
(*val is_aarch64_weak_reference : elf64_symbol_table_entry -> bool*)
let is_aarch64_weak_reference ent:bool=  (Nat_big_num.equal  
(Nat_big_num.of_string (Uint32.to_string ent.elf64_st_shndx)) shn_undef && Nat_big_num.equal    
(get_elf64_symbol_binding ent) stb_weak)

(*val is_aarch64_weak_definition : elf64_symbol_table_entry -> bool*)
let is_aarch64_weak_definition ent:bool=  (not (Nat_big_num.equal (Nat_big_num.of_string (Uint32.to_string ent.elf64_st_shndx)) shn_undef) && Nat_big_num.equal    
(get_elf64_symbol_binding ent) stb_weak)