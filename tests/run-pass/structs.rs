// expect-exit: 0
// rustc-flags: -C panic=abort -C default-linker-libraries

#![no_std]
#![no_main]

use core::panic::PanicInfo;

unsafe extern "C" {
    fn abort() -> !;
}

// A check that panics is a failed test, not one that hangs.
#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    unsafe { abort() }
}

// libcore is compiled to unwind, and on Linux its unwind tables name this function even where panics abort. `std`
// defines it; a `no_std` program that reaches libcore's panic functions has to.
#[unsafe(no_mangle)]
pub extern "C" fn rust_eh_personality() {}

// Two scalars: passed as a pair.
#[derive(Clone, Copy, PartialEq)]
struct Small {
    a: u8,
    b: u32,
}

// Three fields in sixteen bytes: passed as integer registers.
#[derive(Clone, Copy, PartialEq)]
struct Medium {
    a: u64,
    b: u32,
    c: u16,
}

// Too large for registers: passed behind a pointer.
#[derive(Clone, Copy)]
struct Large {
    a: u64,
    b: i64,
    c: f64,
    d: [u32; 4],
}

#[derive(Clone, Copy, PartialEq)]
struct Nested {
    small: Small,
    medium: Medium,
    flag: bool,
    unit: (),
}

// One scalar: passed as that scalar.
#[derive(Clone, Copy)]
struct Meters(f64);

struct Empty;

#[repr(C, packed)]
struct Packed {
    tag: u8,
    value: u32,
    wide: u64,
}

union Bits {
    float: f32,
    int: u32,
}

// Constants that are not scalars: the compiler hands over their bytes, padding and all.
const ORIGIN: Large = Large { a: 3, b: -3, c: 0.25, d: [5, 6, 7, 8] };
const FIRST: Small = Small { a: 9, b: 600 };

impl Small {
    #[inline(never)]
    fn new(a: u8, b: u32) -> Small {
        Small { a, b }
    }

    #[inline(never)]
    fn sum(&self) -> u32 {
        self.a as u32 + self.b
    }

    #[inline(never)]
    fn bump(&mut self) {
        self.a += 1;
        self.b *= 2;
    }

    #[inline(never)]
    fn swapped(self) -> Small {
        Small { a: self.b as u8, b: self.a as u32 }
    }
}

#[inline(never)]
fn medium(seed: u64) -> Medium {
    Medium { a: seed * 1000, b: seed as u32 + 7, c: 9 }
}

#[inline(never)]
fn widen(m: Medium) -> Medium {
    Medium { a: m.a + m.b as u64, b: m.b + m.c as u32, c: m.c + 1 }
}

#[inline(never)]
fn large(seed: u64) -> Large {
    Large { a: seed, b: -(seed as i64) - 4, c: 1.5, d: [seed as u32, 2, 3, 4] }
}

#[inline(never)]
fn shift(mut l: Large, by: u32) -> Large {
    l.a += by as u64;
    l.b -= by as i64;
    l.c *= 2.0;
    l.d[2] += by;
    l
}

#[inline(never)]
fn total(l: &Large) -> i64 {
    l.a as i64 + l.b + l.c as i64 + (l.d[0] + l.d[1] + l.d[2] + l.d[3]) as i64
}

#[inline(never)]
fn nested(small: Small, medium: Medium) -> Nested {
    Nested { small, medium, flag: small.a > 1, unit: () }
}

#[inline(never)]
fn double(m: Meters) -> Meters {
    Meters(m.0 * 2.0)
}

#[inline(never)]
fn nothing(_empty: Empty, n: i32) -> (Empty, i32) {
    (Empty, n + 1)
}

#[inline(never)]
fn packed(tag: u8) -> Packed {
    Packed { tag, value: 0x0102_0304, wide: 0x1122_3344_5566_7788 }
}

#[inline(never)]
fn bits_of(float: f32) -> u32 {
    let bits = Bits { float };
    unsafe { bits.int }
}

#[inline(never)]
fn origin() -> Large {
    ORIGIN
}

#[unsafe(no_mangle)]
pub extern "C" fn main(one: i32, _arguments: *const *const u8) -> i32 {
    let seed = one as u64;

    let mut small = Small::new(one as u8 + 2, 40);
    if small.sum() != 43 {
        return 1;
    }
    small.bump();
    if small.a != 4 || small.b != 80 {
        return 2;
    }
    let swapped = small.swapped();
    let expected = Small { a: 80, b: one as u32 * 4 };
    if swapped != expected || swapped == small {
        return 3;
    }

    let m = widen(medium(seed));
    if m.a != 1008 || m.b != 17 || m.c != 10 {
        return 4;
    }
    let copy = m;
    if copy != m {
        return 5;
    }

    let l = shift(large(seed), 10);
    if l.a != 11 || l.b != -15 || l.c != 3.0 || l.d[0] != 1 || l.d[1] != 2 || l.d[2] != 13 || l.d[3] != 4 {
        return 6;
    }
    if total(&l) != 11 - 15 + 3 + 20 {
        return 7;
    }
    let mut other = l;
    other.d[3] = 0;
    other.c = 0.0;
    if other.d[2] != 13 || l.d[3] != 4 || l.c != 3.0 {
        return 8;
    }

    let n = nested(small, m);
    if !n.flag || n.small.b != 80 || n.medium.c != 10 || n != n {
        return 9;
    }
    let mut changed = n;
    changed.medium.a = 0;
    if changed == n || n.medium.a != 1008 {
        return 10;
    }

    if double(Meters(1.25 * one as f64)).0 != 2.5 {
        return 11;
    }
    if nothing(Empty, 4).1 != 5 {
        return 12;
    }

    let mut p = packed(one as u8);
    p.value += 1;
    let (tag, value, wide) = (p.tag, p.value, p.wide);
    if tag != 1 || value != 0x0102_0305 || wide != 0x1122_3344_5566_7788 {
        return 13;
    }

    if bits_of(one as f32) != 0x3f80_0000 {
        return 14;
    }

    let o = shift(ORIGIN, one as u32);
    if o.a != 4 || o.b != -4 || o.c != 0.5 || o.d[2] != 8 || origin().d[3] != 8 {
        return 15;
    }
    let first = FIRST;
    if first.sum() != 609 || Small::swapped(FIRST).a != 88 {
        return 16;
    }
    0
}
