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

#[derive(Clone, Copy)]
struct Point {
    x: i16,
    y: i64,
}

#[inline(never)]
fn squares(seed: u32) -> [u32; 8] {
    let mut all = [0; 8];
    let mut i = 0;
    while i < 8 {
        all[i] = (i as u32 + seed) * (i as u32 + seed);
        i += 1;
    }
    all
}

#[inline(never)]
fn sum(all: [u32; 8]) -> u32 {
    let mut total = 0;
    let mut i = 0;
    while i < 8 {
        total += all[i];
        i += 1;
    }
    total
}

#[inline(never)]
fn at(all: &[u32; 8], index: usize) -> u32 {
    all[index]
}

#[inline(never)]
fn set(all: &mut [u32; 8], index: usize, value: u32) {
    all[index] = value;
}

#[inline(never)]
fn grid(seed: u8) -> [[u8; 4]; 3] {
    let mut rows = [[seed; 4]; 3];
    let mut row = 0;
    while row < 3 {
        let mut column = 0;
        while column < 4 {
            rows[row][column] += (row * 4 + column) as u8;
            column += 1;
        }
        row += 1;
    }
    rows
}

#[inline(never)]
fn points(seed: i16) -> [Point; 3] {
    [Point { x: seed, y: 10 }, Point { x: seed + 1, y: 20 }, Point { x: seed + 2, y: 30 }]
}

#[inline(never)]
fn primes() -> [u16; 6] {
    [2, 3, 5, 7, 11, 13]
}

#[inline(never)]
fn mean(values: [f64; 4]) -> f64 {
    (values[0] + values[1] + values[2] + values[3]) / 4.0
}

#[inline(never)]
fn fill(value: u64) -> [u64; 100] {
    [value; 100]
}

#[inline(never)]
fn pair(first: u8) -> [u8; 2] {
    [first, first + 1]
}

#[unsafe(no_mangle)]
pub extern "C" fn main(one: i32, _arguments: *const *const u8) -> i32 {
    let index = one as usize;

    let mut all = squares(one as u32);
    if sum(all) != 204 {
        return 1;
    }
    if at(&all, index + 2) != 16 {
        return 2;
    }
    set(&mut all, index, 1000);
    if all[1] != 1000 || all[0] != 1 || all[2] != 9 {
        return 3;
    }

    let rows = grid(one as u8 * 100);
    if rows[0][0] != 100 || rows[2][3] != 111 || rows[index][index + 1] != 106 {
        return 4;
    }

    let mut triangle = points(one as i16);
    triangle[index].y += triangle[index + 1].x as i64;
    if triangle[1].y != 23 || triangle[0].x != 1 || triangle[2].y != 30 {
        return 5;
    }

    let small = primes();
    if small[index + 3] != 11 || small[5] != 13 {
        return 6;
    }

    if mean([1.0, 2.0, 3.0 * one as f64, 6.0]) != 3.0 {
        return 7;
    }

    let many = fill(one as u64 * 3);
    let mut total = 0;
    let mut i = 0;
    while i < 100 {
        total += many[i];
        i += 1;
    }
    if total != 300 {
        return 8;
    }

    let two = pair(one as u8 + 6);
    let [first, second] = two;
    if first != 7 || second != 8 {
        return 9;
    }

    let copy = all;
    all[7] = 0;
    if copy[7] != 64 || all[7] != 0 {
        return 10;
    }
    0
}
