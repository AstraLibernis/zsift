// zsift-vs-rust-csv benchmark. Matched task: parse the whole corpus, sum every
// field's (unquoted) byte length, count records+fields. rust-csv layers:
//   byterecord = csv::Reader + reused ByteRecord (the common high-level fast path)
//   core       = csv_core::Reader (no_std DFA, no allocation — the true peer to zsift)
//   serde      = csv::Reader + deserialize::<Row>() (TYPED rows — the honest peer to
//                zsift's reader(T); parses INTO a struct, not just raw bytes)
// Reads $CORPUS (or argv[2]); best-of-7 internal; prints BENCHFENCE_METRIC=<MB/s>
// on stdout and "records fields sumlen" on stderr for cross-validation.
use std::io::Cursor;
use std::time::Instant;

fn now_ns() -> u128 { Instant::now().elapsed().as_nanos() } // placeholder, replaced below

fn bench_byterecord(data: &[u8]) -> (u64, u64, u64) {
    let mut rdr = csv::ReaderBuilder::new()
        .has_headers(false)
        .flexible(true)
        .from_reader(Cursor::new(data));
    let mut rec = csv::ByteRecord::new();
    let (mut records, mut fields, mut sumlen) = (0u64, 0u64, 0u64);
    while rdr.read_byte_record(&mut rec).expect("valid csv") {
        records += 1;
        for f in rec.iter() { fields += 1; sumlen += f.len() as u64; }
    }
    (records, fields, sumlen)
}

fn bench_core(data: &[u8]) -> (u64, u64, u64) {
    use csv_core::{Reader, ReadFieldResult};
    let mut rdr = Reader::new();
    let mut out = [0u8; 64 * 1024];
    let (mut records, mut fields, mut sumlen) = (0u64, 0u64, 0u64);
    let mut inp = data;
    let mut fields_in_rec = 0u64;
    loop {
        let (res, nin, nout) = rdr.read_field(inp, &mut out);
        inp = &inp[nin..];
        match res {
            ReadFieldResult::InputEmpty => {
                if !inp.is_empty() { continue; }
                if fields_in_rec > 0 { records += 1; }
                break;
            }
            ReadFieldResult::OutputFull => { panic!("field larger than output buffer"); }
            ReadFieldResult::Field { record_end } => {
                fields += 1; fields_in_rec += 1; sumlen += nout as u64;
                if record_end { records += 1; fields_in_rec = 0; }
            }
            ReadFieldResult::End => {
                if fields_in_rec > 0 { records += 1; }
                break;
            }
        }
    }
    (records, fields, sumlen)
}

// Typed row matching zsift's TypedRow and the generated header
// `id,price,flag,name,category`. serde deserializes each record straight into this
// struct — the same work zsift's reader(TypedRow) does — so the comparison is
// apples-to-apples (typed vs typed), unlike the raw-bytes byterecord/core modes.
#[derive(serde::Deserialize)]
struct Row {
    id: i64,
    price: f64,
    flag: bool,
    name: String,
    category: Category,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "lowercase")]
enum Category {
    Alpha,
    Bravo,
    Charlie,
    Delta,
}

fn bench_serde(data: &[u8]) -> (u64, u64, u64) {
    let mut rdr = csv::ReaderBuilder::new()
        .has_headers(true)
        .from_reader(Cursor::new(data));
    let (mut records, mut sumlen) = (0u64, 0u64);
    for r in rdr.deserialize::<Row>() {
        let row = r.expect("valid typed row");
        records += 1;
        sumlen = sumlen
            .wrapping_add(row.id as u64)
            .wrapping_add(row.price.abs() as u64)
            .wrapping_add(row.flag as u64)
            .wrapping_add(row.name.len() as u64)
            .wrapping_add(row.category as u64);
    }
    (records, records, sumlen)
}

fn main() {
    let mode = std::env::args().nth(1).unwrap_or_else(|| "byterecord".into());
    let path = std::env::args().nth(2)
        .or_else(|| std::env::var("CORPUS").ok())
        .expect("need corpus path (argv[2] or $CORPUS)");
    let data = std::fs::read(&path).expect("read corpus");
    let f = match mode.as_str() {
        "byterecord" => bench_byterecord as fn(&[u8]) -> (u64, u64, u64),
        "core" => bench_core as fn(&[u8]) -> (u64, u64, u64),
        "serde" => bench_serde as fn(&[u8]) -> (u64, u64, u64),
        other => panic!("unknown mode '{other}' (byterecord|core|serde)"),
    };
    // warm + validate
    let (records, fields, sumlen) = f(&data);
    // best-of-7
    let mut best = u128::MAX;
    for _ in 0..7 {
        let t0 = Instant::now();
        let r = f(&data);
        let dt = t0.elapsed().as_nanos();
        std::hint::black_box(r);
        if dt < best { best = dt; }
    }
    let secs = best as f64 / 1e9;
    let mib = data.len() as f64 / (1024.0 * 1024.0);
    let mbps = mib / secs;
    println!("BENCHFENCE_METRIC={:.1}", mbps);
    eprintln!("records={records} fields={fields} sumlen={sumlen}");
    let _ = now_ns; // silence unused
}
