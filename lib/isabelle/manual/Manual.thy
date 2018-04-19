(*<*)
theory Manual
  imports
    Sail.State_lemmas
    Sail.Sail_operators_mwords_lemmas
    Sail.Hoare
    Riscv_duopod.Riscv_duopod_lemmas
begin

declare [[show_question_marks = false]]
(*>*)

section \<open>Getting Started\<close>

text \<open>This manual describes how to use Sail specifications for reasoning in Isabelle/HOL.
For instructions on how to set up the Sail tool and its dependencies, see @{path INSTALL.md}.
As an additional setup step for Isabelle generation, it is useful to build an Isabelle heap image
of the Sail library.
This will allow you to start Isabelle with the Sail library pre-loaded using the
@{verbatim "-l Sail"} option.
For this purpose, run @{verbatim make} in the @{path "lib/isabelle"} subdirectory of Sail and
follow the instructions.

In order to generate theorem prover definitions, Sail specifications
are first translated to Lem, which then generates definitions for
Isabelle/HOL.  Lem can also generate HOL4 definitions, though we have
not yet tested that for our ISA specifications.  To produce Coq
definitions, we envisage implementing a direct Sail-to-Coq backend, to
preserve the Sail dependent types (it's possible that the Lem-to-Coq
backend, which in general does not produce good Coq definitions, would
actually produce usable Coq definitions for a monomorphised ISA
specification, but we have not tested that).

The translation to Lem is activated by passing the @{verbatim "-lem"} command line flag to Sail.
For example, the following call in the @{path riscv} directory will generate Lem definitions
for the RISC-V "duopod" (a fragment of the RISC-V specification with only two instructions,
used for illustration purposes):
@{verbatim [display]
"sail -lem -o riscv_duopod -lem_mwords -lem_lib Riscv_extras
  prelude.sail riscv_duopod.sail"}
This uses the following options:
  \<^item> @{verbatim "-lem"} activates the generation of Lem definitions.
  \<^item> @{verbatim "-o riscv_duopod"} specifies the prefix for the output filenames.  This invocation
    of Sail will generate the files
      \<^item> @{path riscv_duopod_types.lem}, containing the definitions of the types used in the
        specification,
      \<^item> @{path riscv_duopod.lem}, containing the main definitions, e.g.~of the instructions, and
      \<^item> @{path Riscv_duopod_lemmas.thy} containing generated helper lemmas, (currently) mainly
        simplification rules for lifting register reads and writes from the free monad to the
        state monad supported by Sail (cf.~Section~\ref{sec:monads}).
  \<^item> @{verbatim "-lem_mwords"} specifies that the generated definitions should use the machine
    word representation of bitvectors (cf.~Section~\ref{sec:mwords}).  This works out-of-the-box
    for the RISC-V specification, but might require monomorphisation (e.g.~using the
    @{verbatim "-auto_mono"} command line flag) for specifications that have functions that
    are polymorphic in bitvector lengths.
  \<^item> @{verbatim "-lem_lib Riscv_extras"} specifies an additional Lem library to be imported.
    It contains Lem implementations for some wrappers and primitive functions that are declared
    as external functions in the Sail source code, such as wrappers for reading and writing memory.

Isabelle definitions can then be generated by passing the @{verbatim "-isa"} flag to Lem.
In order for Lem to find the Sail library, the subdirectories @{path "src/gen_lib"} and
and @{path "src/lem_interp"} of Sail will have to be added to Lem's include path using the
@{verbatim "-lib"} option, e.g.

@{verbatim [display]
"lem -isa -outdir . -lib ../src/lem_interp -lib ../src/gen_lib
  riscv_extras.lem riscv_duopod_types.lem riscv_duopod.lem"}

For further examples, see the @{path Makefile}s of the other specifications included in the Sail
distribution.\<close>

section \<open>An Example of a Sail Specification in Isabelle/HOL\<close>

text \<open>A Sail specification typically comprises a @{term decode} function specifying a mapping from raw
instruction opcodes to a more abstract representation, an @{term execute} function specifying the
behaviour of instructions, further auxiliary functions and datatypes, and register declarations.

For example, in the RISC-V duopod, there are two instructions: a load instruction and an
add instruction with one register and one immediate operand.  Their abstract syntax is represented
using the following datatype:
@{datatype [display] ast}
Both instructions take an immediate 12-bit argument (used as an offset in the case of the load
instruction), and two 5-bit arguments encoding the source and the destination register,
respectively.  The @{term ITYPE} instruction takes another argument encoding the type of operation
(where only addition is implemented in the ``duopod'' fragment of RISC-V).

The function @{term [source] "decode :: 32 word \<Rightarrow> ast option"} is implemented in the Sail source
code using bitvector pattern matching on the opcode.  The Lem backend translates this to an
if-then-else-cascade that compares the given opcode against one pattern after another:
@{thm [display] decode_def[of opcode for opcode]}
This decode function is pure, although decoding might be effectful in other specifications (e.g.,
because the decoding depends on the register state).  Sail uses its effect system to determine
whether a function has side-effects and needs to be be monadic (cf.~Section~\ref{sec:monads} for
more details about the monads).

The @{term execute} function, for example, is monadic.
Its clause for the load instruction of the RISC-V duopod is defined as follows, where
@{text \<bind>} is infix syntax for the monadic bind:
@{thm [display] execute_LOAD_def[of imm rs rd for imm rs rd]}
The instruction first reads the base address from the source register @{term rs}, then adds the
offset given in the immediate argument @{term imm}, calls the @{term MEMr} auxiliary function to
read eight bytes starting at the calculated address, and writes the result into the destination
register @{term rd}.

Note that the @{term execute} function is special-cased in that Sail attempts to split it up into
auxiliary functions (one per AST node) in order to avoid letting it become too large.  The main
@{term execute} function dispatches its inputs to the auxiliary functions:
@{thm [display] execute.simps[of imm rs rd for imm rs rd]}

Apart from function and type definitions, Sail source code contains register declarations.
A @{type regstate} record gets generated from these for use in the state monad, e.g.
@{theory_text [display]
\<open>record regstate  =
 Xs ::" ( 64 Word.word) list "
 nextPC ::"  64 Word.word "
 PC ::"  64 Word.word "\<close>
}
In the RISC-V specification, the general-purpose register file is declared as one register
@{term Xs} containing the 32 registers of 64 bits each, which gets mapped to a list of
64-bit words (see Section~\ref{sec:types} for more information on vectors and lists in general).
In addition to the register state record, a reference constant is generated for each register,
e.g.~@{term PC_ref}, which is used when the register is passed to Sail functions as an argument.
These constants are records that contain the register name as a string, as well as getter and
setter functions.  We discuss them in more detail together with the monads in
Section~\ref{sec:monads}.\<close>

section \<open>Sail Library\<close>

text \<open>The overall theory graph of the Sail library is depicted in Figure~\ref{fig:session-graph}.
The library includes mappings of common operations on the basic types (Section~\ref{sec:types}), in
particular bitvector operations for both the bitlist representation and the machine word
representation of bitvectors (Section~\ref{sec:bitvectors}).
It also includes theories defining the two monads currently supported: a state monad with exceptions
and nondeterminism (cf.~Section~\ref{sec:state-monad}), and a free monad of an effects datatype
(Section~\ref{sec:free-monad}).\<close>

text_raw \<open>
\begin{figure}[p]
  \begin{center}
    \includegraphics[width=\textwidth,height=\textheight,keepaspectratio]{Sail_session_graph}
  \end{center}
  \caption{Session graph of the Sail library \label{fig:session-graph}}
\end{figure}
\<close>

text \<open>The main definitions have been written in Lem and can therefore also be exported to theorem
provers other than Isabelle.  The Isabelle-specific parts of the library are contained in the
theories named with the suffix @{path "_lemmas"}.  They contain mostly simplification rules, but
also congruence rules for the @{term [source] bind} operations of the monads, for example, which
are needed by the function package when processing recursive monadic functions.\<close>

subsection \<open>Basic types \label{sec:types}\<close>

text \<open>The basic Sail types @{verbatim bool}, @{verbatim string}, @{verbatim list}, @{verbatim unit}
and @{verbatim real} are directly mapped to the Isabelle types of the same name.

The numeric types @{verbatim int}, @{verbatim nat}, @{verbatim atom}, and @{verbatim range} are
treated in Sail as integers with constraints.  The latter are not currently translated to Lem
or Isabelle, so these types are all mapped to the Isabelle type @{type int}.

Bits are represented by a type that can also represent undefined bits:
@{datatype [display] bitU}
This provides one way to handle undefined cases of partial functions, such as division by zero.
In general, the guiding principle in the Sail library is to make partiality of library functions
explicit by returning an option type, and to provide wrappers implementing common ways to handle
undefined cases.  For example, the function @{term quot_vec} for bitvector division comes in the
following variants:
  \<^item> @{term quot_vec_maybe} returns an option type, with
    @{lemma "quot_vec_maybe w 0 = None" by (auto simp: quot_vec_maybe_def quot_bv_def arith_op_bv_no0_def)}.
  \<^item> @{term quot_vec_fail} is monadic and either returns the result or raises an exception.
  \<^item> @{term quot_vec_oracle} is monadic and uses the @{term Undefined} effect in the exception case
    to fill the result with bits drawn from a bitstream oracle.
  \<^item> @{term quot_vec} is pure and returns an arbitrary (but fixed) value in the exception case,
    currently defined as follows:  For the bitlist representation of bitvectors,
    @{term "quot_vec w 0"} returns a list filled with @{term BU}, while for the machine word
    representation, the function gets mapped to Isabelle's division operation on machine words,
    which defines @{lemma "(w :: ('a::len) word) div 0 = 0" by (simp add: word_div_def)}.

Which variant is to be used for a given specification can be chosen by using the corresponding
binding for the Lem backend in the Sail source (typically in @{verbatim prelude.sail}).

Vectors in Sail are mapped to lists in Isabelle, except for bitvectors, which are special-cased.
Both increasing and decreasing indexing order are supported by having two versions for each
operation that involves indexing, such as @{term update_list_inc} and @{term update_list_dec},
or @{term subrange_list_inc} and @{term subrange_list_dec}.  These operations are defined in the
theory @{theory Sail_values}, while @{theory Sail_values_lemmas} provides simplification rules
such as

@{lemma "access_list_inc xs i = xs ! nat i" by auto} \\
@{thm access_list_dec_nth}

Note that, while Sail allows functions that are polymorphic in the indexing order, this kind of
polymorphism is not currently supported by the translation to Lem.  It is not needed by the
currently existing specifications, however, since the indexing order is always fixed.\<close>

subsection \<open>Bitvectors \label{sec:bitvectors} \label{sec:mwords}\<close>

(*subsubsection \<open>Bit Lists \label{sec:bitlists}\<close>

subsubsection \<open>Machine Words \label{sec:mwords}\<close>*)

text \<open>The Lem backend of Sail supports two representations of bitvectors: bit lists and machine
words.  The former is less convenient for proofs, because it typically leads to many proof
obligations about bitvector lengths.  These are avoided with machine words, where length
information is contained in the types, e.g.~@{typ "64 word"}.  However, Isabelle/HOL does not support
dependent types, which makes bitvector length polymorphism problematic.  Sail includes an analysis
and rewriting pass for monomorphising bitvector lengths, splitting up length-polymorphic functions
into multiple clauses with concrete bitvector lengths.  This is not enabled by default, however,
so Sail generates Lem definitions using bit lists unless the @{verbatim "-lem_mwords"} command
line flag is used.

The theory @{theory Sail_values} defines a (Lem) typeclass @{verbatim Bitvector}, which provides
an interface to some basic bitvector operations and has instantiations for both bit lists and machine
words.  It is mainly intended for internal use in the Sail library,\<^footnote>\<open>Lem typeclasses are not very
convenient to use in Isabelle, as they get translated to dictionaries that have to be passed to functions
using the typeclass.\<close> to implement library functions supporting either one of the bitvector
representations.  For use in Sail specifications, wrappers are defined in the theories
@{path Sail_operators_bitlists} and @{path Sail_operators_mwords}, respectively.  An import of the
right theory is automatically added to the generated files, depending on which bitvector
representation is used.  Hence, bitvector operations can be referred to in the Sail source code
using uniform names, e.g.~@{term add_vec}, @{term update_vec_dec}, or @{term subrange_vec_inc}.
The theory @{theory Sail_operators_mwords_lemmas} sets up simplification rules that relate these
operations to the native operations in Isabelle, e.g.

@{lemma "add_vec l r = l + r" by simp} \\
@{lemma "and_vec l r = l AND r" by auto} \\
@{thm access_vec_dec_test_bit}\<close>

subsection \<open>Monads \label{sec:monads}\<close>

text \<open>The definitions generated by Sail are designed to support reasoning in both concurrent and
sequential settings.  For the former, we use a free monad of an effect datatype that provides
fine-grained information about the register and memory effects of monadic expressions, suitable
for integration with relaxed memory models.  For the sequential case, we use a state monad (with
exceptions and nondeterminism).

The generated definitions use the free monad, and the sequential case is supported via a lifting
to the state monad defined in the theory @{theory State}.  Simplification rules are set up in the
theory @{theory State_lemmas}, allowing seamless reasoning about the generated definitions in terms
of the state monad.\<close>

subsubsection \<open>State Monad \label{sec:state-monad}\<close>

text \<open>The state monad supports nondeterminism and exceptions and is defined in a standard way:
a monadic expression maps a state to a set of results together with a corresponding successor
state.  The type @{typ "('regs, 'a, 'e) monadS"} is a synonym for
@{typeof [display] "returnS a :: ('regs, 'a, 'e) monadS"}
Here, @{typ "'a"} and @{typ "'e"} are parameters for the return value type and the exception type,
respectively.  The latter is instantiated in generated definitions with either the type
@{term exception}, if the Sail source code defines that type, or with @{typ unit} otherwise.
A result of a monadic expression can be either a value, a non-recoverable failure, or an
exception thrown (that may be caught using @{term try_catch}):
@{datatype [display] ex}
@{datatype [display, names_short] result}

The @{type sequential_state} record has the following fields:
  \<^item> @{term regstate} contains the register state.
  \<^item> @{term memstate} stores the memory, represented as a map from (@{typ int}) addresses to
    (@{typ "bitU list"}) bytes.
  \<^item> Similarly, @{term tagstate} field stores a single bit per address, used by some specifications
    to model tagged memory.
  \<^item> The @{term write_ea} field of type @{typeof "write_ea s"} stores the type, address, and size
    of the last announced memory write, if any.
  \<^item> The @{term last_exclusive_operation_was_load} flag is used to determine whether exclusive
    operations can succeed.
  \<^item> The function stored in the @{term next_bool} field together with the seed in the @{term seed}
    field are used as a random bit generator for undefined values.  The @{term next_bool}
    function takes the current seed as an argument and returns a @{type bool} and the next seed.

The library defines several combinators and wrappers in addition to the standard monadic bind and
return (called @{term bindS} and @{term returnS} here, where the suffix @{term S} differentiates them
from the @{term [source] bind} and @{term return} functions of the free monad).  The functions
@{term readS} and @{term updateS} provide direct access to the state, but there are more specific
wrappers for common tasks such as
  \<^item> @{term read_regS} and @{term write_regS} for accessing registers (taking a register reference
    as an argument),
  \<^item> @{term read_memS} for reading memory,
  \<^item> @{term write_mem_eaS} and @{term write_mem_valS} to announce and perform a memory write,
    respectively, and
  \<^item> @{term undefined_boolS} gets a value from the random bit generator.

Nondeterminism can be introduced using @{term chooseS} to pick a value from a set, failure by
@{term failS} or @{term exitS} (with or without failure message, respectively), assertions by
@{term assert_expS} (causing a failure if the assertion fails), and exceptions by @{term throwS}.
The latter can be caught using @{term try_catchS}, which takes a monadic expression and an
exception handler as arguments.

The exception mechanism is also used to implement early returns by throwing and catching return
values:  A function body with one or more early returns of type @{typ 'a} (and exception type
@{typ 'e}) is lifted to a monadic expression with exception type @{typ "('a + 'e)"} using
@{term liftSR}, such that an early return of the value @{term a} throws @{term "Inl a"}, and a
regular exception @{term e} is thrown as @{term "Inr e"}.  The function body is then wrapped in
@{term catch_early_returnS} to lower it back to the default monad and exception type.  These
liftings and lowerings are automatically inserted by Sail for functions with early returns.\<^footnote>\<open>To be
precise, Sail's Lem backend uses the corresponding constructs for the free monad, but the state
monad version presented here can be obtained using the monad transformation presented in the next
section.\<close>

Finally, there are the loop combinators @{term foreachS}, @{term whileS}, and @{term untilS}.
Loop bodies are required to be of type @{typ unit} in the Sail source code, but during the
translation to Lem they get rewritten into functions that take a tuple with the current values of
local mutable variables that they might update as an (additional) argument, and return the updated
values.  Hence, the type of @{term foreachS}, for example, is
@{term [display, source] "foreachS :: 'a list \<Rightarrow> 'vars \<Rightarrow> ('a \<Rightarrow> 'vars \<Rightarrow> ('regs, 'vars, 'e) monadS) \<Rightarrow> ('regs, 'vars, 'e) monadS"}
Note that there is no general termination proof for @{term whileS} and @{term untilS}, so the
termination predicates @{term "whileS_dom"} or @{term "untilS_dom"} have to be proved for concrete
instances.\<close>

subsubsection \<open>Free Monad \label{sec:free-monad}\<close>

text \<open>In addition to the state monad, the Sail library defines a monad in the theory @{theory Prompt_monad}
that is essentially a (flattened) free monad of an effect datatype.  A monadic expression either
returns a pure value @{term a}, denoted @{term "Done a"}, or it has an effect.  The latter can be
a failure or an exception, or an effect together with a continuation.  For example,
@{term \<open>Read_reg ''PC'' k\<close>} represents a request to read the register @{term PC} and continue as
@{term k}, which is a function that takes the register value as a parameter and returns another
monadic expression.  The complete set of supported effects is captured in the following datatype:

@{datatype [display] monad}

The same set of combinators and wrappers as for the state monad is defined for this monad.  The
names are the same, but without the suffix @{term S}, e.g.~@{term read_reg}, @{term write_mem_val},
@{term undefined_bool}, @{term throw}, @{term try_catch}, etc.~(with the exception of the loop
combinators, which are called @{term foreachM}, @{term whileM}, and @{term untilM}; the names
@{term foreach}, @{term [names_short] while}, and @{term until} are reserved for the pure versions
of the loop combinators).

The monad is parametric in the register type used for the register effects.  One technical
complication is that, in general, this requires a single type that can subsume all the types of
registers occurring in a specification.  Otherwise, it would not be possible to find a single
instantiation of the @{type monad} type to assign to a function that involves reading or writing
multiple registers with different types, for example.  To solve this problem, the translation from
Sail to Lem generates a union type @{typ register_value} including all register types of the given
specification.  For example, in the case of the RISC-V duopod, this is\<^footnote>\<open>The @{term Regval_list}
and @{term Regval_option} constructors are not actually used in the RISC-V duopod, but they are
always generated by default.\<close>

@{datatype [display] register_value}

Sail also generates conversion functions to and from @{type register_value}, e.g.

@{term [source, show_types] "regval_of_vector_64_dec_bit :: 64 word \<Rightarrow> register_value"} \\
@{term [source, show_types] "vector_64_dec_bit_of_regval :: register_value \<Rightarrow> 64 word option"}

where the latter is partial.  The matching pair of conversion functions for each register is
recorded in its @{type register_ref} record, e.g.

@{thm [display] PC_ref_def}

The @{term read_reg} wrapper, for example, takes such a reference as a parameter, generates a
@{term Read_reg} effect with the register name, and casts the register value received as input via
@{term of_regval}.  If the latter fails because the environment passed a value of the wrong type
to the continuation, then @{term read_reg} halts with a @{term Failure}.  The state monad wrappers
@{term read_regS} and @{term write_regS} also take such a register reference as an argument, but
use the getters and setters in the @{term read_from} and @{term write_to} fields to access the
register state record:
@{thm [display] read_regS_def write_regS_def}

Sail aims to generate Isabelle definitions that can be used with either the state or the free monad.
To achieve this, the definitions are generated using the free monad, and a lifting to the state
monad is provided together with simplification rules.  These include generic simplification rules
(proved in the theory @{theory State_lemmas}) such as
@{thm [display]
    liftState_return[where r = "(get_regval, set_regval)"]
    liftState_bind[where r = "(get_regval, set_regval)"]
    liftState_try_catch[where r = "(get_regval, set_regval)"]}
They also include more specific lemmas about register reads and writes:  The lifting of these
involves a back-and-forth conversion between the type of the register and the @{type register_value}
type at the interface between the monads, which can fail in general.  As long as the generated
register references are used, however, it is guaranteed to succeed, and this is made explicit in
lemmas such as
@{thm [display] liftS_read_reg_PC liftS_write_reg_PC}
which are generated (together with their proofs) for each register and placed in a theory with
the suffix @{path "_lemmas"}, e.g.~@{path Riscv_duopod_lemmas}.
The aim of these lemmas is to allow a smooth transition from the free to the state monad via
simplification, as in the following example.\<close>

section \<open>Example Proof \label{sec:ex-proof}\<close>

text \<open>As a toy example for illustration, we prove that the add instruction in the RISC-V duopod
actually performs an addition.  We consider the sequential case and use the state monad. The
theory @{theory Hoare} defines (a shallow embedding of) a simple Hoare logic, where
@{term "PrePost P f Q"} denotes a triple of a precondition @{term P}, monadic expression @{term f},
and postcondition @{term Q}.  Its validity is defined by
@{thm [display] PrePost_def}
There is also a quadruple variant, with separate postconditions for the regular and the exception
case, defined as
@{thm [display, names_short] PrePostE_def}
The theory includes standard proof rules for both of these variants, in particular rules
giving weakest preconditions of the predefined primitives of the monad, collected under the names
@{attribute PrePost_intro} and @{attribute PrePostE_intro}, respectively.

The instruction we are considering is defined as
@{thm [display] execute_ITYPE.simps[of _ rs for rs]}

We first declare two simplification rules and an abbreviation, for stating the lemma more
conveniently: @{term "getXs r s"} reads general-purpose register @{term r} in state @{term s},
where register 0 is special-cased and hard-wired to the constant 0, as defined in the RISC-V
specification.\<close>

abbreviation "getXs r s \<equiv> if r = 0 then 0 else access_list_dec (Xs (regstate s)) (uint r)"

lemma EXTS_scast[simp]: "EXTS len w = scast w"
  by (simp add: EXTS_def sign_extend_def)

declare regbits_to_regno_def[simp]

text \<open>We prove that a postcondition of the instruction is that the destination register holds the
sum of the initial value of the source register and the immediate operand (unless the destination
register is the constant zero register).  Moreover, we require the instruction to succeed, so
the postcondition for the exception case is @{term False}.  In the precondition, we remember
the initial value @{term v} of the source register for use in the postcondition (since it might get
overwritten if @{term "rs = rd"}).  We also explicitly assume that there are 32 general-purpose
registers; due to the use of a list for the @{term Xs} register file, this information is currently
not preserved by the translation.\<close>

lemma
  fixes rs rd :: regbits and v :: "64 word" and imm :: "12 word"

  defines "pre s \<equiv> (getXs rs s = v \<and> length (Xs (regstate s)) = 32)"
  defines "instr \<equiv> execute (ITYPE (imm, rs, rd, RISCV_ADDI))"
  defines "post a s \<equiv> (rd = 0 \<or> getXs rd s = v + (scast imm))"

  shows "PrePostE pre (liftS instr) post (\<lambda>_ _. False)"

  unfolding pre_def instr_def post_def
  by (simp add: rX_def wX_def cong: bindS_cong if_cong split del: if_split)
     (rule PrePostE_strengthen_pre, (rule PrePostE_intro)+, auto simp: uint_0_iff)

text \<open>The proof begins with a simplification step, which not only unfolds the definitions of the
auxiliary functions @{term rX} and @{term wX}, but also performs the lifting from the free monad
to the state monad.  We apply the rule @{thm [source] PrePostE_strengthen_pre} (in a
backward manner) to allow a weaker precondition, then use the rules in @{attribute PrePostE_intro}
to derive a weakest precondition, and then use @{method auto} to show that it is implied by
the given precondition.  For more serious proofs, one will want to set up specialised proof
tactics.  This example uses only basic proof methods, to make the reasoning steps more explicit.\<close>

(*<*)
end
(*>*)
