#!/usr/bin/env python3
import json
import os
import sys


REQUIRED_KEYS = ("slug", "allowed_paths", "acceptance")
OPTIONAL_KEYS = ("depends_on", "forbidden_paths")
KNOWN_KEYS = set(REQUIRED_KEYS + OPTIONAL_KEYS)
SLUG_PATTERN = "^[a-z0-9][a-z0-9-]*$"


def _valid_slug(value):
    if not isinstance(value, str) or value == "":
        return False
    first = value[0]
    if not ("a" <= first <= "z" or "0" <= first <= "9"):
        return False
    for char in value:
        if not ("a" <= char <= "z" or "0" <= char <= "9" or char == "-"):
            return False
    return True


def _require_string(value, field):
    if not isinstance(value, str) or value == "":
        raise ValueError("%s must be a non-empty string" % field)
    return value


def _require_string_array(value, field, allow_empty):
    if not isinstance(value, list):
        raise ValueError("%s must be an array of strings" % field)
    if not allow_empty and not value:
        raise ValueError("%s must be non-empty" % field)
    for index, item in enumerate(value):
        if not isinstance(item, str) or item == "":
            raise ValueError("%s[%d] must be a non-empty string" % (field, index))
    return list(value)


def _require_depends_on(value):
    if not isinstance(value, list):
        raise ValueError("depends_on must be an array of strings")
    for index, item in enumerate(value):
        if not isinstance(item, str):
            raise ValueError("depends_on[%d] must be a string" % index)
    return list(value)


def _validate_order(data):
    if not isinstance(data, dict):
        raise ValueError("top-level order must be a JSON object")

    unknown = sorted(key for key in data.keys() if key not in KNOWN_KEYS)
    if unknown:
        raise ValueError("unknown top-level keys: %s" % ", ".join(unknown))

    for key in REQUIRED_KEYS:
        if key not in data:
            raise ValueError("missing required field: %s" % key)

    slug = data["slug"]
    if not _valid_slug(slug):
        raise ValueError("slug must be a non-empty string matching %s" % SLUG_PATTERN)

    return {
        "slug": slug,
        "allowed_paths": _require_string_array(
            data["allowed_paths"], "allowed_paths", False
        ),
        "acceptance": _require_string(data["acceptance"], "acceptance"),
        "depends_on": _require_depends_on(data.get("depends_on", [])),
        "forbidden_paths": _require_string_array(
            data.get("forbidden_paths", []), "forbidden_paths", True
        ),
    }


def load_order(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except OSError as exc:
        raise ValueError("cannot read file: %s" % exc.strerror) from exc
    except json.JSONDecodeError as exc:
        raise ValueError(
            "invalid JSON: %s at line %d column %d"
            % (exc.msg, exc.lineno, exc.colno)
        ) from exc
    return _validate_order(data)


def _normalize_path(value):
    normalized = value.replace("\\", "/")
    normalized = os.path.normpath(normalized).replace(os.sep, "/")
    if normalized == ".":
        return ""
    return normalized


def _segment_matches(pattern, text):
    rows = len(pattern) + 1
    cols = len(text) + 1
    table = [[False for _ in range(cols)] for _ in range(rows)]
    table[0][0] = True

    for p_index in range(1, rows):
        char = pattern[p_index - 1]
        if char == "*":
            table[p_index][0] = table[p_index - 1][0]
        for t_index in range(1, cols):
            char = pattern[p_index - 1]
            if char == "*":
                table[p_index][t_index] = (
                    table[p_index - 1][t_index] or table[p_index][t_index - 1]
                )
            elif char == "?" or char == text[t_index - 1]:
                table[p_index][t_index] = table[p_index - 1][t_index - 1]

    return table[-1][-1]


def path_matches(pattern, filepath):
    pattern_parts = _normalize_path(pattern).split("/")
    file_parts = _normalize_path(filepath).split("/")
    memo = {}

    def matches(pattern_index, file_index):
        key = (pattern_index, file_index)
        if key in memo:
            return memo[key]
        if pattern_index == len(pattern_parts):
            result = file_index == len(file_parts)
        elif pattern_parts[pattern_index] == "**":
            result = False
            for next_file_index in range(file_index, len(file_parts) + 1):
                if matches(pattern_index + 1, next_file_index):
                    result = True
                    break
        elif file_index < len(file_parts) and _segment_matches(
            pattern_parts[pattern_index], file_parts[file_index]
        ):
            result = matches(pattern_index + 1, file_index + 1)
        else:
            result = False
        memo[key] = result
        return result

    return matches(0, 0)


def main(argv):
    if len(argv) < 2:
        print("Usage: python3 order_lint.py <order.json> [<order.json> ...]")
        return 1

    all_valid = True
    for path in argv[1:]:
        try:
            order = load_order(path)
        except ValueError as exc:
            all_valid = False
            print("INVALID %s: %s" % (path, exc))
        else:
            print("OK %s %s" % (order["slug"], path))

    return 0 if all_valid else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
