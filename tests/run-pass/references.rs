// expect-exit: 0
// rustc-flags: -C panic=abort -C default-linker-libraries

#![no_std]
#![no_main]
#![feature(core_intrinsics)]
#![allow(internal_features)]

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

struct Counter {
    count: u32,
    step: u32,
}

#[inline(never)]
fn increment(n: &mut u32) {
    *n += 1;
}

#[inline(never)]
fn larger<'a>(a: &'a u32, b: &'a u32) -> &'a u32 {
    if *a > *b { a } else { b }
}

#[inline(never)]
fn swap(a: &mut u64, b: &mut u64) {
    let kept = *a;
    *a = *b;
    *b = kept;
}

#[inline(never)]
fn advance(counter: &mut Counter) -> &mut u32 {
    counter.count += counter.step;
    &mut counter.count
}

#[inline(never)]
fn through(n: &&mut &u8) -> u8 {
    ***n
}

#[inline(never)]
unsafe fn write(to: *mut i32, value: i32) {
    unsafe { *to = value }
}

#[inline(never)]
unsafe fn read(from: *const i32) -> i32 {
    unsafe { *from }
}

#[inline(never)]
unsafe fn third(first: *const u16) -> u16 {
    unsafe { *core::intrinsics::offset(first, 2usize) }
}

#[inline(never)]
unsafe fn copy(from: *const u32, to: *mut u32, count: usize) {
    unsafe { core::intrinsics::copy_nonoverlapping(from, to, count) }
}

#[unsafe(no_mangle)]
pub extern "C" fn main(one: i32, _arguments: *const *const u8) -> i32 {
    let mut n = one as u32 + 4;
    increment(&mut n);
    increment(&mut n);
    if n != 7 {
        return 1;
    }

    let other = 5;
    if *larger(&n, &other) != 7 || !core::ptr::eq(larger(&other, &n), &n) {
        return 2;
    }

    let (mut a, mut b) = (one as u64, 2);
    swap(&mut a, &mut b);
    if a != 2 || b != 1 {
        return 3;
    }

    let mut counter = Counter { count: 10, step: one as u32 * 5 };
    *advance(&mut counter) += 1;
    let count = advance(&mut counter);
    *count *= 2;
    if counter.count != 42 {
        return 4;
    }

    let byte = one as u8 + 8;
    let mut shared = &byte;
    if through(&&mut shared) != 9 {
        return 5;
    }

    let mut value = 0;
    let raw = &raw mut value;
    unsafe { write(raw, one + 10) };
    if unsafe { read(raw) } != 11 || value != 11 {
        return 6;
    }
    let address = raw as usize;
    if unsafe { read(address as *const i32) } != 11 {
        return 7;
    }

    let words = [one as u16, 20, 30, 40];
    if unsafe { third(&raw const words as *const u16) } != 30 {
        return 8;
    }

    let from = [one as u32 * 3, 4, 5];
    let mut to = [0; 4];
    unsafe { copy(&raw const from as *const u32, &raw mut to as *mut u32, 3) };
    if to[0] != 3 || to[1] != 4 || to[2] != 5 || to[3] != 0 {
        return 9;
    }

    let field = &mut counter.step;
    *field += 1;
    let whole = &counter;
    if whole.step != 6 {
        return 10;
    }
    0
}
