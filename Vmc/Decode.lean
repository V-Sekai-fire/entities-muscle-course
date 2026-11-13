/-! VMC / OSC decoder. A port of DigitOtter/godot-vmc-lib (MIT) `vmc_receiver.cpp`'s message handling,
with oscpack and the UDP thread removed: a guest cannot bind a socket, so the host reads UDP and hands
each datagram to `feed`. No I/O, no Godot, no sandbox. `guest/vmc/main.cpp` exports it to the host.

Differences from upstream, on purpose:
* every read is bounds-checked and a bad packet is counted, never asserted (upstream asserts argument
  counts, which a release build compiles out and then reads past the end);
* `/VMC/Ext/{Hmd,Con,Tra}/Pos` are decoded into trackers (upstream leaves them in `other_data`); they
  are the tracker poses the `mm.elf` query takes as features;
* a string that is not UTF-8 makes its message bad (upstream passes the bytes through).
-/
namespace Vmc

structure Pose where
  px : Float32 := 0
  py : Float32 := 0
  pz : Float32 := 0
  qx : Float32 := 0
  qy : Float32 := 0
  qz : Float32 := 0
  qw : Float32 := 1

inductive Arg where
  | num (v : Float)
  | str (s : String)
  | other

structure State where
  time : Float32 := 0
  bones : Array (String × Pose) := #[]
  roots : Array (String × Pose) := #[]
  trackers : Array (String × Pose) := #[]
  blend : Array (String × Float32) := #[]
  pending : Array (String × Float32) := #[]
  cam : Pose := {}
  camFov : Float32 := 0
  unknown : Array (String × Nat) := #[]
  messages : Nat := 0
  vmcCount : Nat := 0
  unknownCount : Nat := 0
  bad : Nat := 0
  lastOk : Bool := true

/-! ### Wire reading -/

def be32 (d : ByteArray) (i : Nat) : UInt32 :=
  ((d.get! i).toUInt32 <<< 24) ||| ((d.get! (i + 1)).toUInt32 <<< 16) |||
    ((d.get! (i + 2)).toUInt32 <<< 8) ||| (d.get! (i + 3)).toUInt32

def be64 (d : ByteArray) (i : Nat) : UInt64 :=
  ((be32 d i).toUInt64 <<< 32) ||| (be32 d (i + 4)).toUInt64

def findNul (d : ByteArray) (hi : Nat) : Nat → Nat → Option Nat
  | _, 0 => none
  | e, fuel + 1 => if e >= hi then none else if d.get! e == 0 then some e else findNul d hi (e + 1) fuel

/-- A NUL-terminated string padded to a multiple of 4 bytes, read from `[p, hi)`. -/
def readStr (d : ByteArray) (p hi : Nat) : Option (String × Nat) :=
  match findNul d hi p (hi - p) with
  | none => none
  | some e =>
    let next := p + (e - p + 4) / 4 * 4
    if next > hi then none
    else match String.fromUTF8? (d.extract p e) with
      | none => none
      | some s => some (s, next)

def int32Float (u : UInt32) : Float :=
  let n := u.toNat
  Float.ofInt (if n >= 2147483648 then (n : Int) - 4294967296 else (n : Int))

def readArgs (d : ByteArray) (hi : Nat) : List Char → Nat → Array Arg → Option (Array Arg × Nat)
  | [], p, acc => some (acc, p)
  | c :: cs, p, acc =>
    if c == 'i' then
      if p + 4 > hi then none else readArgs d hi cs (p + 4) (acc.push (.num (int32Float (be32 d p))))
    else if c == 'f' then
      if p + 4 > hi then none
      else readArgs d hi cs (p + 4) (acc.push (.num (Float32.ofBits (be32 d p)).toFloat))
    else if c == 'd' then
      if p + 8 > hi then none else readArgs d hi cs (p + 8) (acc.push (.num (Float.ofBits (be64 d p))))
    else if c == 'c' then
      if p + 4 > hi then none else readArgs d hi cs (p + 4) (acc.push .other)
    else if c == 'h' then
      if p + 8 > hi then none else readArgs d hi cs (p + 8) (acc.push .other)
    else if c == 's' || c == 'S' then
      match readStr d p hi with
      | none => none
      | some (s, q) => readArgs d hi cs q (acc.push (.str s))
    else if c == 'T' || c == 'F' || c == 'N' || c == 'I' then
      readArgs d hi cs p (acc.push .other)
    else if c == 'b' then
      if p + 4 > hi then none
      else
        let len := (be32 d p).toNat
        let q := p + 4
        let padded := (len + 3) / 4 * 4
        if len > hi - q || padded > hi - q then none else readArgs d hi cs (q + padded) (acc.push .other)
    else none -- an unknown type tag: the rest cannot be framed

def parseMessage (d : ByteArray) (lo hi : Nat) : Option (String × Array Arg) := do
  let (addr, p) ← readStr d lo hi
  if !addr.startsWith "/" then failure
  let (tags, p) ← if p >= hi then some (",", p) else readStr d p hi
  if !tags.startsWith "," then failure
  let (args, _) ← readArgs d hi (tags.toList.drop 1) p #[]
  some (addr, args)

/-! ### Dispatch -/

def numsAt (a : Array Arg) (start count : Nat) : Bool :=
  if a.size < start + count then false
  else (List.range count).all fun i => match a[start + i]? with
    | some (.num _) => true
    | _ => false

def numAt (a : Array Arg) (i : Nat) : Float32 :=
  match a[i]? with
  | some (.num v) => v.toFloat32
  | _ => 0

def strAt (a : Array Arg) (i : Nat) : Option String :=
  match a[i]? with
  | some (.str s) => some s
  | _ => none

def poseAt (a : Array Arg) (i : Nat) : Pose :=
  { px := numAt a i, py := numAt a (i + 1), pz := numAt a (i + 2),
    qx := numAt a (i + 3), qy := numAt a (i + 4), qz := numAt a (i + 5), qw := numAt a (i + 6) }

def upsert {α : Type} (m : Array (String × α)) (k : String) (v : α) : Array (String × α) :=
  match m.findIdx? (fun e => e.1 == k) with
  | some i => m.set! i (k, v)
  | none => m.push (k, v)

def badOne (s : State) : State := { s with bad := s.bad + 1 }

def dispatch (s : State) (addr : String) (a : Array Arg) : State :=
  let known := { s with vmcCount := s.vmcCount + 1 }
  if addr == "/VMC/Ext/T" then
    if numsAt a 0 1 then { known with time := numAt a 0 } else badOne known
  else if addr == "/VMC/Ext/Blend/Val" then
    match strAt a 0 with
    | some name => if numsAt a 1 1 then { known with pending := upsert known.pending name (numAt a 1) } else badOne known
    | none => badOne known
  else if addr == "/VMC/Ext/Blend/Apply" then
    { known with blend := known.pending, pending := #[] }
  else if addr == "/VMC/Ext/Bone/Pos" then
    match strAt a 0 with
    | some name => if numsAt a 1 7 then { known with bones := upsert known.bones name (poseAt a 1) } else badOne known
    | none => badOne known
  else if addr == "/VMC/Ext/Root/Pos" then
    match strAt a 0 with
    | some name => if numsAt a 1 7 then { known with roots := upsert known.roots name (poseAt a 1) } else badOne known
    | none => badOne known
  else if addr == "/VMC/Ext/Cam" then
    -- argument 0 is the camera name; upstream skips it without reading it
    if numsAt a 1 7 then { known with cam := poseAt a 1, camFov := if numsAt a 8 1 then numAt a 8 else 0 }
    else badOne known
  else if addr == "/VMC/Ext/Hmd/Pos" || addr == "/VMC/Ext/Con/Pos" || addr == "/VMC/Ext/Tra/Pos" then
    let kind := if addr == "/VMC/Ext/Hmd/Pos" then "hmd:" else if addr == "/VMC/Ext/Con/Pos" then "con:" else "tra:"
    match strAt a 0 with
    | some name => if numsAt a 1 7 then { known with trackers := upsert known.trackers (kind ++ name) (poseAt a 1) } else badOne known
    | none => badOne known
  else
    let n := match s.unknown.find? (fun e => e.1 == addr) with
      | some e => e.2 + 1
      | none => 1
    { s with unknownCount := s.unknownCount + 1, unknown := upsert s.unknown addr n }

/-! ### Packets -/

def isBundle (d : ByteArray) (lo hi : Nat) : Bool :=
  hi - lo >= 8 &&
    [35, 98, 117, 110, 100, 108, 101, 0].zipIdx.all fun (b, i) => d.get! (lo + i) == (b : UInt8)

mutual
  /-- One datagram or bundle element in `[lo, hi)`. Returns the new state and whether it was well formed. -/
  partial def packet (s : State) (d : ByteArray) (lo hi depth : Nat) : State × Bool :=
    if hi == lo || depth > 8 then (badOne s, false)
    else if isBundle d lo hi then
      if hi - lo < 16 then (badOne s, false) else elements s d (lo + 16) hi depth true
    else match parseMessage d lo hi with
      | none => (badOne s, false)
      | some (addr, args) => (dispatch { s with messages := s.messages + 1 } addr args, true)

  partial def elements (s : State) (d : ByteArray) (p hi depth : Nat) (ok : Bool) : State × Bool :=
    if p >= hi then (s, ok)
    else if p + 4 > hi then (badOne s, false)
    else
      let len := (be32 d p).toNat
      let q := p + 4
      if len > hi - q then (badOne s, false)
      else
        let (s', ok') := packet s d q (q + len) (depth + 1)
        elements s' d (q + len) hi depth (ok && ok')
end

def feedState (s : State) (b : ByteArray) : State :=
  let (s', ok) := packet s b 0 b.size 0
  { s' with lastOk := ok }

/-! ### Reading state back -/

def sortedByKey {α : Type} (m : Array (String × α)) : Array (String × α) :=
  m.qsort fun a b => a.1 < b.1

def namesText {α : Type} (m : Array (String × α)) : String :=
  (sortedByKey m).foldl (fun acc e => acc ++ e.1 ++ "\n") ""

def poseFloats (p : Pose) : Array Float :=
  #[p.px.toFloat, p.py.toFloat, p.pz.toFloat, p.qx.toFloat, p.qy.toFloat, p.qz.toFloat, p.qw.toFloat]

def rowsOf (m : Array (String × Pose)) : FloatArray :=
  FloatArray.mk ((sortedByKey m).foldl (fun acc e => acc ++ poseFloats e.2) #[])

def statsText (s : State) : String :=
  "messages " ++ toString s.messages ++ " vmc " ++ toString s.vmcCount ++ " unknown " ++
    toString s.unknownCount ++ " bad " ++ toString s.bad

def unknownText (s : State) : String :=
  (sortedByKey s.unknown).foldl (fun acc e => acc ++ e.1 ++ " " ++ toString e.2 ++ "\n") ""

/-! ### C exports (called by guest/vmc/main.cpp; every argument is owned) -/

@[export vmc_new] def exportNew (_ : Unit) : State := {}
@[export vmc_feed_bytes] def exportFeed (s : State) (b : ByteArray) : State := feedState s b
@[export vmc_last_ok] def exportLastOk (s : State) : UInt8 := if s.lastOk then 1 else 0
@[export vmc_stats_text] def exportStats (s : State) : String := statsText s
@[export vmc_time_value] def exportTime (s : State) : Float := s.time.toFloat
@[export vmc_bones_text] def exportBones (s : State) : String := namesText s.bones
@[export vmc_roots_text] def exportRoots (s : State) : String := namesText s.roots
@[export vmc_trackers_text] def exportTrackers (s : State) : String := namesText s.trackers
@[export vmc_bone_floats] def exportBoneRows (s : State) : FloatArray := rowsOf s.bones
@[export vmc_root_floats] def exportRootRows (s : State) : FloatArray := rowsOf s.roots
@[export vmc_tracker_floats] def exportTrackerRows (s : State) : FloatArray := rowsOf s.trackers
@[export vmc_blend_names] def exportBlendNames (s : State) : String := namesText s.blend
@[export vmc_blend_floats] def exportBlendValues (s : State) : FloatArray :=
  FloatArray.mk ((sortedByKey s.blend).map fun e => e.2.toFloat)
@[export vmc_camera_floats] def exportCamera (s : State) : FloatArray :=
  FloatArray.mk (poseFloats s.cam |>.push s.camFov.toFloat)
@[export vmc_unknown_text] def exportUnknown (s : State) : String := unknownText s

end Vmc
