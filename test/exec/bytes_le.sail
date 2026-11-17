default Order dec
$include <prelude.sail>

val check_bytes : forall 'n, 0 < 'n <= 16. (int('n), bits(8 * 'n)) -> unit

function check_bytes(n, b) = {
    let v = to_bytes_le(n, b);
    print_bits("byte 0 = ", v[0]);
    print_bits("last byte = ", v[n - 1]);
    let b2 : bits(8 * 'n) = from_bytes_le(n, v);
    print_bits("round trip = ", b2);
    if b2 != b then print_endline("round trip failed")
}

val main : unit -> unit

function main() = {
    let w : bits(32) = 0x12345678;
    let v = to_bytes_le(4, w);
    print_bits("v[0] = ", v[0]);
    print_bits("v[3] = ", v[3]);
    let w2 : bits(32) = from_bytes_le(4, v);
    print_bits("w2 = ", w2);
    check_bytes(1, 0xAB);
    check_bytes(2, 0xCDEF);
    check_bytes(8, 0x0123456789ABCDEF);
    check_bytes(16, 0xFEDCBA98765432100123456789ABCDEF)
}
