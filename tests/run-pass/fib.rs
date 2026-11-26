// expect-exit: 55
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

fn fib(n: u32) -> u32 {
    if n < 2 { n } else { fib(n - 1) + fib(n - 2) }
}

fn fib_loop(n: u32) -> u64 {
    let mut previous = 0u64;
    let mut current = 1u64;
    let mut step = 0;
    while step < n {
        let next = previous + current;
        previous = current;
        current = next;
        step += 1;
    }
    previous
}

#[unsafe(no_mangle)]
pub extern "C" fn main() -> i32 {
    if fib(20) != 6765 {
        return 1;
    }
    if fib_loop(90) != 2880067194370816120 {
        return 2;
    }
    if fib_loop(10) != fib(10) as u64 {
        return 3;
    }
    fib(10) as i32
}
