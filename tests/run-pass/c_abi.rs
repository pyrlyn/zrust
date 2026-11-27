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

// The C library's own `div_t` and `lldiv_t`: what `div` and `lldiv` return, compiled by a C compiler.
#[repr(C)]
struct Div {
    quot: i32,
    rem: i32,
}

#[repr(C)]
struct LongDiv {
    quot: i64,
    rem: i64,
}

unsafe extern "C" {
    fn div(numerator: i32, denominator: i32) -> Div;
    fn lldiv(numerator: i64, denominator: i64) -> LongDiv;
}

#[repr(C)]
#[derive(Clone, Copy)]
struct Tiny {
    a: u8,
    b: u8,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct Floats {
    a: f32,
    b: f32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct Mixed {
    a: i64,
    b: f64,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct Vector {
    x: f64,
    y: f64,
    z: f64,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct Big {
    values: [u64; 5],
}

#[inline(never)]
extern "C" fn tiny(t: Tiny, add: u8) -> Tiny {
    Tiny { a: t.b + add, b: t.a }
}

#[inline(never)]
extern "C" fn floats(f: Floats) -> Floats {
    Floats { a: f.a + f.b, b: f.a - f.b }
}

#[inline(never)]
extern "C" fn mixed(m: Mixed, scale: f64) -> Mixed {
    Mixed { a: m.a * 2, b: m.b * scale }
}

#[inline(never)]
extern "C" fn cross(a: Vector, b: Vector) -> Vector {
    Vector { x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x }
}

#[inline(never)]
extern "C" fn reversed(first: u8, big: Big, last: i16) -> Big {
    let v = big.values;
    Big { values: [v[4] + first as u64, v[3], v[2], v[1], (v[0] as i64 + last as i64) as u64] }
}

#[inline(never)]
extern "C" fn many(a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, h: i64, m: Mixed, v: Vector, i: i64) -> f64 {
    (a + b + c + d + e + f + g + h + i + m.a) as f64 + m.b + v.x + v.y + v.z
}

#[unsafe(no_mangle)]
pub extern "C" fn main(one: i32, _arguments: *const *const u8) -> i32 {
    let short = unsafe { div(47 * one, 5) };
    if short.quot != 9 || short.rem != 2 {
        return 1;
    }
    let long = unsafe { lldiv(-10_000_000_007 * one as i64, 1_000_000) };
    if long.quot != -10_000 || long.rem != -7 {
        return 2;
    }

    let t = tiny(Tiny { a: one as u8, b: 2 }, 5);
    if t.a != 7 || t.b != 1 {
        return 3;
    }

    let f = floats(Floats { a: 1.5 * one as f32, b: 0.25 });
    if f.a != 1.75 || f.b != 1.25 {
        return 4;
    }

    let m = mixed(Mixed { a: one as i64 * 21, b: 0.5 }, 4.0);
    if m.a != 42 || m.b != 2.0 {
        return 5;
    }

    let x = Vector { x: one as f64, y: 0.0, z: 0.0 };
    let y = Vector { x: 0.0, y: 1.0, z: 0.0 };
    let z = cross(x, y);
    if z.x != 0.0 || z.y != 0.0 || z.z != 1.0 {
        return 6;
    }

    let big = reversed(one as u8, Big { values: [1, 2, 3, 4, 5] }, -1);
    let v = big.values;
    if v[0] != 6 || v[1] != 4 || v[2] != 3 || v[3] != 2 || v[4] != 0 {
        return 7;
    }

    if many(1, 2, 3, 4, 5, 6, 7, 8, m, z, one as i64 * 9) != 90.0 {
        return 8;
    }
    0
}
