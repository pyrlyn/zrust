//! The rustc codegen backend of ZRust: the only Rust code in the project.
//!
//! It stays thin on purpose. rustc loads this dylib through `-Zcodegen-backend`;
//! real code generation happens in the Zig `zrust-codegen` process.

#![feature(rustc_private)]

extern crate rustc_attr_ir;
extern crate rustc_codegen_ssa;
// Not used by name, but the dylib must link against rustc's own driver library
// to resolve compiler symbols once rustc loads it.
extern crate rustc_driver;
extern crate rustc_metadata;
extern crate rustc_middle;
extern crate rustc_public;
extern crate rustc_public_bridge;
extern crate rustc_session;
extern crate rustc_span;
extern crate rustc_target;
extern crate serde;
extern crate serde_json;
extern crate smallvec;

mod backend;
mod encode;
mod zrmir;

use rustc_codegen_ssa::traits::CodegenBackend;

/// The symbol rustc looks up after loading a `-Zcodegen-backend` dylib.
#[unsafe(no_mangle)]
pub fn __rustc_codegen_backend() -> Box<dyn CodegenBackend> {
    Box::new(backend::ZrustBackend)
}
