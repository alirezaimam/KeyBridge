package control

import "testing"

func TestValidateText(t *testing.T) {
	for _, text := range []string{"Hello-VMware_123!@#", "plain text"} {
		if err := ValidateText(text, 256); err != nil {
			t.Fatalf("%q: %v", text, err)
		}
	}
	for _, text := range []string{"", "line\nbreak", "tab\tvalue", "café"} {
		if err := ValidateText(text, 256); err == nil {
			t.Fatalf("accepted %q", text)
		}
	}
	if err := ValidateText("12345", 4); err == nil {
		t.Fatal("accepted oversized text")
	}
}
