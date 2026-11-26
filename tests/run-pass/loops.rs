// expect-exit: 42
// rustc-flags: -C panic=abort -C default-linker-libraries

#![no_std]
#![no_main]

use core::panic::PanicInfo;

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {}
}

fn sum_to(n: u32) -> u32 {
    let mut total = 0;
    let mut i = 1;
    while i <= n {
        total += i;
        i += 1;
    }
    total
}

fn count_primes(below: u32) -> u32 {
    let mut count = 0;
    let mut candidate = 2;
    'candidates: while candidate < below {
        let mut divisor = 2;
        while divisor * divisor <= candidate {
            if candidate % divisor == 0 {
                candidate += 1;
                continue 'candidates;
            }
            divisor += 1;
        }
        count += 1;
        candidate += 1;
    }
    count
}

fn collatz_steps(mut n: u64) -> u32 {
    let mut steps = 0;
    loop {
        if n == 1 {
            break steps;
        }
        n = if n % 2 == 0 { n / 2 } else { 3 * n + 1 };
        steps += 1;
    }
}

fn gcd(a: u32, b: u32) -> u32 {
    if b == 0 { a } else { gcd(b, a % b) }
}

fn is_even(n: u32) -> bool {
    if n == 0 { true } else { is_odd(n - 1) }
}

fn is_odd(n: u32) -> bool {
    if n == 0 { false } else { is_even(n - 1) }
}

fn classify(n: i32) -> i32 {
    match n {
        0 => 10,
        1 | 2 => 20,
        3..=9 => 30,
        -1 => 40,
        _ => 50,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn main() -> i32 {
    if sum_to(100) != 5050 {
        return 1;
    }
    if count_primes(100) != 25 {
        return 2;
    }
    if collatz_steps(27) != 111 {
        return 3;
    }
    if gcd(1071, 462) != 21 {
        return 4;
    }
    if !is_even(10) || is_even(7) || !is_odd(7) {
        return 5;
    }
    if classify(0) + classify(2) + classify(5) + classify(-1) + classify(77) != 150 {
        return 6;
    }
    42
}
