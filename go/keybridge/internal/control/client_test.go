package control

import "testing"

func TestSettingsValidation(t *testing.T) {
	valid := Settings{MaxLength: 256, KeyDownMS: 40, KeyUpMS: 40}
	if !valid.Valid() {
		t.Fatal("expected valid defaults")
	}
	for _, setting := range []Settings{{MaxLength: 0, KeyDownMS: 40, KeyUpMS: 40}, {MaxLength: 256, KeyDownMS: 0, KeyUpMS: 40}, {MaxLength: 256, KeyDownMS: 40, KeyUpMS: 0}, {MaxLength: 256, KeyDownMS: 40, KeyUpMS: 40, InterKeyMS: 60_001}, {MaxLength: 256, KeyDownMS: 40, KeyUpMS: 40, StartDelayMS: 60_001}} {
		if setting.Valid() {
			t.Fatalf("accepted invalid settings: %+v", setting)
		}
	}
}

func TestWireIsLittleEndian(t *testing.T) {
	got := Settings{MaxLength: 0x01020304, KeyDownMS: 1, KeyUpMS: 2, InterKeyMS: 3, StartDelayMS: 4}.wire()
	want := []byte{4, 3, 2, 1, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0}
	if string(got) != string(want) {
		t.Fatalf("wire = %v, want %v", got, want)
	}
}
