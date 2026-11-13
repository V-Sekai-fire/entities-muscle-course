import Vmc.Decode
open Vmc

/-! Native witness for `Vmc.Decode`: the cases of tests/vmc_decode_test.cpp, from the same
hand-computed wire bytes. `lake exe vmc_witness` prints `RESULT: PASS` and exits 0. With `--control`
it plants a wrong expectation and must exit 1. -/

def put32 (b : ByteArray) (u : UInt32) : ByteArray :=
  b.push (u >>> 24).toUInt8 |>.push (u >>> 16).toUInt8 |>.push (u >>> 8).toUInt8 |>.push u.toUInt8

partial def padTo4 (b : ByteArray) : ByteArray := if b.size % 4 == 0 then b else padTo4 (b.push 0)

def pstr (b : ByteArray) (s : String) : ByteArray := padTo4 ((b ++ s.toUTF8).push 0)

inductive A where | f (v : Float32) | s (v : String) | i (v : Int)

def msg (addr : String) (args : List A) : ByteArray := Id.run do
  let mut tags := ","
  let mut body := ByteArray.empty
  for a in args do
    match a with
    | .f v => tags := tags ++ "f"; body := put32 body v.toBits
    | .s v => tags := tags ++ "s"; body := pstr body v
    | .i v => tags := tags ++ "i"; body := put32 body (if v < 0 then (4294967296 + v).toNat.toUInt32 else v.toNat.toUInt32)
  return (pstr (pstr ByteArray.empty addr) tags) ++ body

def bundle (els : List ByteArray) : ByteArray := Id.run do
  let mut o := pstr ByteArray.empty "#bundle"
  for k in [0:8] do o := o.push (if k == 7 then 1 else 0)
  for e in els do o := put32 o e.size.toUInt32 ++ e
  return o

def pose (name : String) (v : List Float32) : List A := A.s name :: v.map A.f
def find? {α : Type} (m : Array (String × α)) (k : String) : Option α := (m.find? (·.1 == k)).map (·.2)

def run (control : Bool) : IO Nat := do
  let mut fails := 0
  let check := fun (ok : Bool) (what : String) => do
    if !ok then IO.println s!"FAIL {what}"
    return !ok
  -- wire format: /VMC/Ext/T with 0.5, bytes worked out by hand
  let t := msg "/VMC/Ext/T" [.f 0.5]
  let want := ByteArray.mk #[47,86,77,67,47,69,120,116,47,84,0,0, 44,102,0,0, 0x3f,0,0,0]
  if (← check (t == want) "wire bytes") then fails := fails + 1
  let s := feedState {} t
  if (← check (s.lastOk && s.time == (if control then 0.75 else 0.5)) "time") then fails := fails + 1
  -- a bundle of bone, root, blend and apply
  let pk := bundle [
    msg "/VMC/Ext/Root/Pos" (pose "root" [1, 2, 3, 0, 0, 0, 1]),
    msg "/VMC/Ext/Bone/Pos" (pose "Hips" [0.1, 0.2, 0.3, 0.5, 0.5, 0.5, 0.5]),
    msg "/VMC/Ext/Bone/Pos" (pose "Head" [0, 1.6, 0, 0, 0, 0, 1]),
    msg "/VMC/Ext/Blend/Val" [.s "Joy", .f 0.25],
    msg "/VMC/Ext/T" [.f 12.5]]
  let s := feedState {} pk
  if (← check (s.lastOk && s.bones.size == 2) "bundle bones") then fails := fails + 1
  if (← check ((find? s.bones "Hips").map (·.py) == some 0.2 && (find? s.bones "Hips").map (·.qw) == some 0.5) "Hips") then fails := fails + 1
  if (← check ((find? s.roots "root").map (·.pz) == some 3.0) "root") then fails := fails + 1
  if (← check (s.blend.isEmpty && (find? s.pending "Joy") == some 0.25) "blend pending") then fails := fails + 1
  let s := feedState s (msg "/VMC/Ext/Blend/Apply" [])
  if (← check ((find? s.blend "Joy") == some 0.25 && s.pending.isEmpty) "blend applied") then fails := fails + 1
  if (← check (s.time == 12.5 && s.bad == 0 && s.messages == 6) "counts") then fails := fails + 1
  if (← check (namesText s.bones == "Head\nHips\n") "names sorted") then fails := fails + 1
  if (← check ((rowsOf s.bones).size == 14) "rows size") then fails := fails + 1
  -- trackers and camera with fov
  let s := feedState {} (msg "/VMC/Ext/Hmd/Pos" (pose "HMD" [0, 1.7, 0, 0, 0, 0, 1]))
  let s := feedState s (msg "/VMC/Ext/Tra/Pos" (pose "LHAND" [-0.3, 1.2, 0.1, 0, 0, 0, 1]))
  let s := feedState s (msg "/VMC/Ext/Cam" (pose "Camera" [0, 1, 2, 0, 0, 0, 1] ++ [.f 40]))
  if (← check ((find? s.trackers "hmd:HMD").map (·.py) == some 1.7) "hmd") then fails := fails + 1
  if (← check ((find? s.trackers "tra:LHAND").map (·.px) == some (-0.3)) "tra") then fails := fails + 1
  if (← check (s.cam.pz == 2.0 && s.camFov == 40.0) "camera") then fails := fails + 1
  -- unknown address is kept by name, not an error
  let s := feedState {} (msg "/VMC/Ext/Midi/Note" [.i 1, .i 0, .i 60, .f 0.5])
  if (← check (s.lastOk && s.unknownCount == 1 && s.vmcCount == 0 && s.unknown.size == 1) "unknown") then fails := fails + 1
  -- negative int32 sign
  let s := feedState {} (msg "/VMC/Ext/T" [.i (-3)])
  if (← check (s.time == -3.0) "int32 sign") then fails := fails + 1
  -- malformed input is rejected and counted, never read past the end
  let ok := msg "/VMC/Ext/Bone/Pos" (pose "Hips" [0, 0, 0, 0, 0, 0, 1])
  let mut cutsBad := 0
  for cut in [1:ok.size] do
    let e := feedState {} (ok.extract 0 cut)
    if !e.bones.isEmpty then cutsBad := cutsBad + 1
  if (← check (cutsBad == 0) "truncations") then fails := fails + 1
  let s := feedState {} (msg "/VMC/Ext/Bone/Pos" [.s "Hips", .f 0, .f 0])
  if (← check (s.bones.isEmpty && s.bad == 1) "short args") then fails := fails + 1
  let s := feedState s (msg "/VMC/Ext/Bone/Pos" ([A.f 1] ++ ([0,0,0,0,0,0,1].map A.f)))
  if (← check (s.bones.isEmpty && s.bad == 2) "wrong type") then fails := fails + 1
  let mut bl := bundle [msg "/VMC/Ext/T" [.f 1]]
  bl := bl.set! 19 0xff
  if (← check (!(feedState {} bl).lastOk) "bad bundle length") then fails := fails + 1
  if (← check (!(feedState {} (ByteArray.mk #[120,121,122])).lastOk) "junk") then fails := fails + 1
  if (← check (!(feedState {} ByteArray.empty).lastOk) "empty") then fails := fails + 1
  let mut deep := bundle [msg "/VMC/Ext/T" [.f 1]]
  for _ in [0:20] do deep := bundle [deep]
  if (← check (!(feedState {} deep).lastOk) "nesting cap") then fails := fails + 1
  -- A bone name that is not UTF-8 makes the message bad. Upstream passes the bytes through; this is
  -- a decision (see Vmc/Decode.lean), pinned here so it cannot change unnoticed.
  let mut raw := pstr (pstr ByteArray.empty "/VMC/Ext/Bone/Pos") ",sfffffff"
  raw := raw ++ padTo4 (ByteArray.mk #[0xe9, 0x4d, 0x00])
  for v in ([0, 0, 0, 0, 0, 0, 1] : List Float32) do raw := put32 raw v.toBits
  let s := feedState {} raw
  if (← check (!s.lastOk && s.bones.isEmpty && s.bad == 1) "non-UTF-8 name is bad") then fails := fails + 1
  return fails

def main (args : List String) : IO UInt32 := do
  let fails ← run (args.contains "--control")
  IO.println (if fails == 0 then "RESULT: PASS" else s!"RESULT: FAIL ({fails})")
  return if fails == 0 then 0 else 1
