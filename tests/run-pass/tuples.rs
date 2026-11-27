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

#[inline(never)]
fn pair(n: i32) -> (i32, bool) {
    (n * 3, n > 0)
}

#[inline(never)]
fn triple(n: u64) -> (u64, u64, u64) {
    (n, n * n, n * n * n)
}

#[inline(never)]
fn nest(n: u8) -> ((u8, u16), (u32, u64)) {
    ((n, n as u16 * 300), (n as u32 * 70_000, n as u64 * 5_000_000_000))
}

#[inline(never)]
fn swap(both: (u16, f64)) -> (f64, u16) {
    (both.1, both.0)
}

#[inline(never)]
fn rotate(all: (u64, u64, u64)) -> (u64, u64, u64) {
    (all.1, all.2, all.0)
}

#[inline(never)]
fn unit(_nothing: ()) {}

#[inline(never)]
fn div_rem(n: u32, by: u32) -> (u32, u32) {
    (n / by, n % by)
}

#[unsafe(no_mangle)]
pub extern "C" fn main(one: i32, _arguments: *const *const u8) -> i32 {
    let (tripled, positive) = pair(one * 7);
    if tripled != 21 || !positive {
        return 1;
    }

    let cubes = triple(one as u64 + 2);
    if cubes.0 != 3 || cubes.1 != 9 || cubes.2 != 27 {
        return 2;
    }
    let rotated = rotate(rotate(cubes));
    if rotated.0 != 27 || rotated.1 != 3 || rotated.2 != 9 || rotated == cubes {
        return 3;
    }

    let ((a, b), (c, d)) = nest(one as u8 * 2);
    if a != 2 || b != 600 || c != 140_000 || d != 10_000_000_000 {
        return 4;
    }

    let swapped = swap((one as u16 + 4, 0.5));
    if swapped.0 != 0.5 || swapped.1 != 5 {
        return 5;
    }

    unit(());
    let mut both = div_rem(47 * one as u32, 5);
    both.0 += both.1;
    if both.0 != 11 || both.1 != 2 {
        return 6;
    }

    let mut nested = (cubes, (swapped, both));
    nested.1.1.1 = 9;
    (nested.0).0 = (nested.1).0.1 as u64;
    let (first, (_, second)) = nested;
    if first.0 != 5 || first.1 != 9 || first.2 != 27 || second.0 != 11 || second.1 != 9 || both.1 != 2 {
        return 7;
    }
    0
}
