// expect-exit: 0
// rustc-flags: -C panic=abort -C default-linker-libraries

#![no_std]
#![no_main]

use core::panic::PanicInfo;

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {}
}

// libcore is compiled to unwind, and on Linux its unwind tables name this function even where panics abort. `std`
// defines it; a `no_std` program that reaches libcore's panic functions has to.
#[unsafe(no_mangle)]
pub extern "C" fn rust_eh_personality() {}

// As in `ops.rs`, `one` is the argument count of the process: nothing here is known while compiling.

fn integers(one: i32) -> bool {
    let n = one * 300;
    let m = -one;
    n as u8 == 44
        && n as i8 == 44
        && (n + 100) as i8 == -112
        && m as u8 == 255
        && m as u32 == u32::MAX
        && m as i64 == -1
        && m as u32 as u64 == 4294967295
        && m as i128 == -1
        && m as u16 as i128 == 65535
        && (one as u128) << 70 >> 68 == 4
        && ((one as u128) << 70) as u64 == 0
        && (one == 1) as i32 == 1
        && (one == 2) as u8 == 0
        && 'a' as u32 + one as u32 == 98
        && (96 + one as u8) as char == 'a'
}

fn floats(one: i32) -> bool {
    let x = one as f64 * 2.75;
    let infinity = x / 0.0;
    let nan = infinity - infinity;
    x as i32 == 2
        && -x as i32 == -2
        && -x as u32 == 0
        && (x * 1e20) as i32 == i32::MAX
        && (x * -1e20) as i32 == i32::MIN
        && (x * 1e20) as u8 == 255
        && infinity as u64 == u64::MAX
        && nan as i32 == 0
        && x as f32 as f64 == 2.75
        && (one as f32 * 0.5) as f64 == 0.5
        && (one as u64 * u64::MAX) as f64 == 18446744073709551616.0
        && -one as f32 == -1.0
        && (one as u8 * 255) as f32 == 255.0
        && x.to_bits() == 0x4006_0000_0000_0000
        && f32::from_bits(0x3f80_0000 * one as u32) == 1.0
}

fn pointers(one: i32) -> bool {
    let address = one as usize * 4096;
    let bytes = address as *const u8;
    let words = bytes as *const u32;
    let writable = words as *mut u32;
    let function: fn(i32) -> bool = integers;
    words as usize == 4096
        && writable as *const u32 == words
        && writable as usize + 4 == 4100
        && function as usize != 0
        && function as *const () as usize == function as usize
}

#[unsafe(no_mangle)]
pub extern "C" fn main(one: i32, _arguments: *const *const u8) -> i32 {
    if !integers(one) {
        return 1;
    }
    if !floats(one) {
        return 2;
    }
    if !pointers(one) {
        return 3;
    }
    0
}
