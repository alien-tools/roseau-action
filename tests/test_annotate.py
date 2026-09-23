import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from annotate import Anchor, FileDiff, anchor, annotation, comment_body, fingerprint, should_annotate  # noqa: E402

# src/main/java/p/A.java, v1 -> v2:
#   1 package p;              1 package p;
#   2                         2
#   3 public class A {        3 public class A {
#   4   public void m() {}    -
#   5   public int f;         4   public long f;
#                             5   public void added() {}
#   6 }                       6 }
A_PATCH = """@@ -1,6 +1,6 @@
 package p;

 public class A {
-  public void m() {}
-  public int f;
+  public long f;
+  public void added() {}
 }"""


def files(*entries):
    return [FileDiff.parse(e) for e in entries]


def a_java(path="src/main/java/p/A.java", **extra):
    return {"filename": path, "status": "modified", "patch": A_PATCH, **extra}


def change(kind, location=None, new_location=None, **extra):
    return {"kind": kind, "impactedType": "p.A", "impactedSymbol": "p.A.m()", "location": location,
            "newLocation": new_location, "binaryBreaking": True, "sourceBreaking": True, **extra}


def at(path, line):
    return {"path": path, "line": line}


class ParseTest(unittest.TestCase):
    def test_lines_are_classified_by_side(self):
        diff = FileDiff.parse(a_java())
        self.assertEqual(diff.deleted, {4, 5})
        self.assertEqual(diff.added, {4, 5})
        self.assertEqual(diff.context, {1: 1, 2: 2, 3: 3, 6: 6})
        self.assertEqual(diff.removed_at, {4: 4, 5: 4})

    def test_missing_patch_has_no_commentable_lines(self):
        diff = FileDiff.parse({"filename": "big.java", "status": "modified"})
        self.assertEqual((diff.deleted, diff.added, diff.context), (set(), set(), {}))


class AnchorTest(unittest.TestCase):
    def test_removed_symbol_is_anchored_on_its_deleted_line(self):
        where = anchor(change("EXECUTABLE_REMOVED", at("p/A.java", 4)), files(a_java()))
        self.assertEqual(where, Anchor("src/main/java/p/A.java", "LEFT", 4, 4))

    def test_modified_symbol_is_anchored_on_its_new_line(self):
        where = anchor(change("FIELD_TYPE_CHANGED", at("p/A.java", 5), at("p/A.java", 4)), files(a_java()))
        self.assertEqual(where, Anchor("src/main/java/p/A.java", "RIGHT", 4, 4))

    def test_added_symbol_is_anchored_on_its_added_line(self):
        where = anchor(change("TYPE_NEW_ABSTRACT_METHOD", at("p/A.java", 3), at("p/A.java", 5)), files(a_java()))
        self.assertEqual(where, Anchor("src/main/java/p/A.java", "RIGHT", 5, 5))

    def test_old_location_on_context_line_is_anchored_on_the_new_side(self):
        where = anchor(change("CLASS_NOW_FINAL", at("p/A.java", 6)), files(a_java()))
        self.assertEqual(where, Anchor("src/main/java/p/A.java", "RIGHT", 6, 6))

    def test_new_location_outside_the_diff_falls_back_to_the_old_location(self):
        where = anchor(change("METHOD_NOW_STATIC", at("p/A.java", 4), at("p/A.java", 42)), files(a_java()))
        self.assertEqual(where, Anchor("src/main/java/p/A.java", "LEFT", 4, 4))

    def test_removed_file_has_no_annotation_line(self):
        removed = {"filename": "src/main/java/p/Gone.java", "status": "removed",
                   "patch": "@@ -1,3 +0,0 @@\n-package p;\n-\n-public class Gone {}"}
        where = anchor(change("TYPE_REMOVED", at("p/Gone.java", 3)), files(removed))
        self.assertEqual(where, Anchor("src/main/java/p/Gone.java", "LEFT", 3, None))

    def test_renamed_file_is_matched_on_its_previous_path(self):
        renamed = a_java("src/main/java/q/A.java", status="renamed", previous_filename="src/main/java/p/A.java")
        where = anchor(change("EXECUTABLE_REMOVED", at("p/A.java", 4)), files(renamed))
        self.assertEqual(where, Anchor("src/main/java/q/A.java", "LEFT", 4, 4))

    def test_location_outside_the_diff_is_not_anchored(self):
        self.assertIsNone(anchor(change("EXECUTABLE_REMOVED", at("p/Other.java", 4)), files(a_java())))
        self.assertIsNone(anchor(change("EXECUTABLE_REMOVED", None), files(a_java())))

    def test_ambiguous_paths_are_not_anchored(self):
        diff = files(a_java("module-a/src/main/java/p/A.java"), a_java("module-b/src/main/java/p/A.java"))
        self.assertIsNone(anchor(change("EXECUTABLE_REMOVED", at("p/A.java", 4)), diff))

    def test_suffix_matching_respects_path_segments(self):
        self.assertIsNone(anchor(change("EXECUTABLE_REMOVED", at("A.java", 4)), files(a_java("src/p/BA.java"))))


class OutputTest(unittest.TestCase):
    def test_annotation_escapes_properties(self):
        c = change("EXECUTABLE_REMOVED", at("p/A.java", 4), impactedSymbol="p.A.m(int,java.lang.String)")
        self.assertEqual(annotation("error", [c], "src/A.java", 4),
                         "::error file=src/A.java,line=4,title=Roseau%3A Executable removed::"
                         "p.A.m(int,java.lang.String) (binary-breaking and source-breaking)")

    def test_annotation_without_file(self):
        self.assertTrue(annotation("warning", [change("TYPE_REMOVED")], None, None).startswith("::warning title="))

    def test_changes_on_the_same_line_are_grouped(self):
        changes = [change("METHOD_RETURN_TYPE_ERASURE_CHANGED"), change("METHOD_RETURN_TYPE_CHANGED_INCOMPATIBLE")]
        self.assertIn("title=Roseau%3A 2 breaking changes::", annotation("error", changes, "A.java", 4))
        self.assertIn("**Roseau: 2 breaking changes**", comment_body(changes, Anchor("A.java", "LEFT", 4, 4)))

    def test_comment_links_to_the_documentation_of_the_kind(self):
        body = comment_body([change("EXECUTABLE_REMOVED")], Anchor("A.java", "LEFT", 4, 4))
        self.assertIn("(https://alien-tools.github.io/roseau/stable/breaking-change-kinds/#executable_removed)", body)

    def test_fingerprint_depends_on_the_anchor(self):
        c = change("EXECUTABLE_REMOVED", at("p/A.java", 4))
        self.assertNotEqual(fingerprint([c], Anchor("A.java", "LEFT", 4, 4)), fingerprint([c], Anchor("A.java", "LEFT", 5, 5)))

    def test_fingerprint_ignores_report_order(self):
        a, b = change("EXECUTABLE_REMOVED"), change("FIELD_REMOVED")
        where = Anchor("A.java", "LEFT", 4, 4)
        self.assertEqual(fingerprint([a, b], where), fingerprint([b, a], where))


class ShouldAnnotateTest(unittest.TestCase):
    def test_auto_only_annotates_what_inline_comments_do_not_mark(self):
        self.assertFalse(should_annotate("auto", commented=True))
        self.assertTrue(should_annotate("auto", commented=False))
        self.assertTrue(should_annotate("auto", commented=True, outside_located=True))

    def test_true_and_false_ignore_inline_comments(self):
        self.assertTrue(should_annotate("true", commented=True))
        self.assertFalse(should_annotate("false", commented=False))
        self.assertFalse(should_annotate("false", commented=True, outside_located=True))


if __name__ == "__main__":
    unittest.main()
