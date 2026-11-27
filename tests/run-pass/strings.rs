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

static GREETING: &str = "hello";
static WORDS: [&str; 3] = ["alpha", "beta", "gamma"];
static mut CURRENT: &str = "first";

const MAGIC: &[u8; 4] = b"\x00\x01\xfe\xff";
const EMPTY: &str = "";

struct Label {
    text: &'static str,
    code: u8,
}

const LABEL: Label = Label { text: "label", code: 7 };

#[inline(never)]
fn length(text: &str) -> usize {
    text.len()
}

#[inline(never)]
fn byte(text: &str, index: usize) -> u8 {
    text.as_bytes()[index]
}

#[inline(never)]
fn pick(left: bool) -> &'static str {
    if left { "left" } else { "right, the longer one" }
}

#[inline(never)]
fn count(text: &str, wanted: u8) -> usize {
    let bytes = text.as_bytes();
    let mut found = 0;
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == wanted {
            found += 1;
        }
        index += 1;
    }
    found
}

#[inline(never)]
fn equal(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    let mut index = 0;
    while index < a.len() {
        if a[index] != b[index] {
            return false;
        }
        index += 1;
    }
    true
}

#[inline(never)]
fn word(index: usize) -> &'static str {
    WORDS[index]
}

#[inline(never)]
fn label() -> Label {
    LABEL
}

#[inline(never)]
fn checksum(bytes: &[u8]) -> u32 {
    let mut total = 0;
    let mut index = 0;
    while index < bytes.len() {
        total = total * 31 + bytes[index] as u32;
        index += 1;
    }
    total
}

#[inline(never)]
fn first_byte(text: &str) -> u8 {
    unsafe { *text.as_ptr() }
}

#[inline(never)]
fn raw(text: &str) -> *const str {
    text
}

#[unsafe(no_mangle)]
pub extern "C" fn main(one: i32, _arguments: *const *const u8) -> i32 {
    if length("four") != 4 || length(EMPTY) != 0 || length("наука") != 10 {
        return 1;
    }
    if byte("abc", one as usize) != b'b' || byte(GREETING, 4) != b'o' {
        return 2;
    }
    if !equal(pick(one == 1), "left") || length(pick(one != 1)) != 21 {
        return 3;
    }
    if count("mississippi", b's') != 4 || count("mississippi", b'x') != 0 {
        return 4;
    }
    if !equal(word(0), "alpha") || !equal(word(2), "gamma") || equal(word(1), "bet") {
        return 5;
    }
    let label = label();
    if !equal(label.text, "label") || label.code != 7 {
        return 6;
    }
    if MAGIC[2] != 0xfe || checksum(MAGIC) != 31 * 31 + 0xfe * 31 + 0xff {
        return 7;
    }
    if checksum(b"ab") != 97 * 31 + 98 || checksum("ab".as_bytes()) != 97 * 31 + 98 {
        return 8;
    }
    if first_byte("zrust") != b'z' {
        return 9;
    }
    unsafe {
        if !equal(CURRENT, "first") {
            return 10;
        }
        CURRENT = "second, and longer";
        if length(CURRENT) != 18 {
            return 11;
        }
    }
    let pointer = raw(GREETING);
    if !equal(unsafe { &*pointer }, "hello") || pointer as *const u8 != GREETING.as_ptr() {
        return 12;
    }
    0
}
