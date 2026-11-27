//! The rustc codegen backend of ZRust: the only Rust code in the project.
//!
//! It stays thin on purpose. rustc loads this dylib through `-Zcodegen-backend`;
//! real code generation happens in the Zig `zrust-codegen` process.

#![feature(rustc_private)]

extern crate rustc_codegen_ssa;
// Not used by name, but the dylib must link against rustc's own driver library
// to resolve compiler symbols once rustc loads it.
extern crate rustc_driver;
extern crate rustc_middle;
extern crate rustc_session;
extern crate smallvec;

mod backend;

use rustc_codegen_ssa::traits::CodegenBackend;

/// The symbol rustc looks up after loading a `-Zcodegen-backend` dylib.
#[unsafe(no_mangle)]
pub fn __rustc_codegen_backend() -> Box<dyn CodegenBackend> {
    Box::new(backend::ZrustBackend)
}
