// expect-stdout: 14
// expect-stdout: 3
// expect-stdout: 30
// expect-stdout: 6
// unsupported: needs phase A6 (`std`)

fn apply(f: impl Fn(i32) -> i32, value: i32) -> i32 {
    f(value)
}

fn call_twice(f: &mut dyn FnMut()) {
    f();
    f();
}

fn double(value: i32) -> i32 {
    value * 2
}

fn make_adder(by: i32) -> Box<dyn Fn(i32) -> i32> {
    Box::new(move |value| value + by)
}

fn main() {
    let offset = 4;
    println!("{}", apply(|value| value + offset, 10));

    let mut count = 1;
    call_twice(&mut || count += 1);
    println!("{count}");

    let pointer: fn(i32) -> i32 = double;
    println!("{}", make_adder(10)(pointer(10)));

    let evens: i32 = (1..=5).filter(|value| value % 2 == 0).sum();
    println!("{evens}");
}
