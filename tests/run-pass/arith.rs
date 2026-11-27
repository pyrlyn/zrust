// expect-stdout: 255 -1 4294967295
// expect-stdout: 2.5 3 -3
// expect-stdout: None Some(250)
// expect-stdout: 340282366920938463463374607431768211455
// expect-stdout: 16 3 1
// expect-stdout: a 97

#[inline(never)]
fn opaque<T>(value: T) -> T {
    std::hint::black_box(value)
}

fn main() {
    let byte: u8 = opaque(255);
    println!("{} {} {}", byte, byte as i8, byte as i8 as u32);

    let float: f64 = opaque(2.5);
    println!("{} {} {}", float, (float + 0.5) as i32, (-float - 0.5) as i64);

    println!("{:?} {:?}", byte.checked_add(1), byte.checked_sub(5));
    println!("{}", u128::MAX);

    let x: u32 = opaque(8);
    println!("{} {} {}", x << 1, x.trailing_zeros(), x >> 3);

    let letter = opaque('a');
    println!("{} {}", letter, letter as u32);
}
