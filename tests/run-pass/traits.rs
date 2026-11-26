// expect-stdout: woof
// expect-stdout: meow
// expect-stdout: 2 legs total 8
// expect-stdout: dropped rex

trait Animal {
    fn name(&self) -> &str;
    fn speak(&self) -> String;
    fn legs(&self) -> u32 {
        4
    }
}

struct Dog {
    name: String,
}

struct Cat;

impl Animal for Dog {
    fn name(&self) -> &str {
        &self.name
    }
    fn speak(&self) -> String {
        String::from("woof")
    }
}

impl Animal for Cat {
    fn name(&self) -> &str {
        "cat"
    }
    fn speak(&self) -> String {
        String::from("meow")
    }
}

impl Drop for Dog {
    fn drop(&mut self) {
        println!("dropped {}", self.name);
    }
}

fn total_legs<T: Animal + ?Sized>(animals: &[Box<T>]) -> u32 {
    animals.iter().map(|animal| animal.legs()).sum()
}

fn main() {
    let animals: Vec<Box<dyn Animal>> = vec![Box::new(Dog { name: String::from("rex") }), Box::new(Cat)];
    for animal in &animals {
        println!("{}", animal.speak());
    }
    println!("{} legs total {}", animals.len(), total_legs(&animals));
}
