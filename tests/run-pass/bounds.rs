// expect-panic: index out of bounds
// rustc-flags: -C panic=abort -C default-linker-libraries

#![no_std]
#![no_main]

use core::panic::PanicInfo;

unsafe extern "C" {
    fn abort() -> !;
}

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    unsafe { abort() }
}

// libcore is compiled to unwind, and on Linux its unwind tables name this function even where panics abort. `std`
// defines it; a `no_std` program that reaches libcore's panic functions has to.
#[unsafe(no_mangle)]
pub extern "C" fn rust_eh_personality() {}

#[inline(never)]
fn at(all: &[i32; 4], index: usize) -> i32 {
    all[index]
}

#[unsafe(no_mangle)]
pub extern "C" fn main(one: i32, _arguments: *const *const u8) -> i32 {
    let all = [one, 2, 3, 4];
    let mut total = 0;
    let mut index = 0;
    while index < 8 {
        total += at(&all, index);
        index += 1;
    }
    total
}
