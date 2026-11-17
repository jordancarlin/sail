default Order dec
$include <prelude.sail>

// Add and subtract an integer to a bitvector of at most 64 bits. The C
// backend compiles these without lbits.

val add_sub : forall 'n, 0 < 'n <= 64. (bits('n), range(-4096, 4096)) -> unit

function add_sub(x, i) = {
    print_bits("add ", x + i);
    print_bits("sub ", x - i)
}

val add_sub_int : forall 'n, 0 < 'n <= 64. (bits('n), int) -> unit

function add_sub_int(x, i) = {
    print_bits("add int ", x + i);
    print_bits("sub int ", x - i)
}

val main : unit -> unit

function main() = {
    let a : bits(64) = 0xFFFFFFFFFFFFFFFF;
    let b : bits(12) = 0xFFE;
    let c : bits(8) = 0x01;
    print_bits("fixed add ", a + 1);
    print_bits("fixed sub ", a - 3);
    print_bits("fixed12 add ", b + 5);
    print_bits("fixed12 sub ", b - (-3));
    print_bits("fixed8 sub ", c - 2);
    add_sub(a, 1);
    add_sub(a, -1);
    add_sub(b, 4095);
    add_sub(c, -255);
    add_sub(0b1, 1);
    add_sub_int(b, 4097);
    add_sub_int(a, 2 ^ 64 + 1)
}
