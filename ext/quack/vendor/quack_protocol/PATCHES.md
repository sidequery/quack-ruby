# Packaged protocol fixes

Source: bnjjj/quack_protocol_rs 0.4.1, commit
ee5cf21e3450b0651dd0fe9ed94e455c3b3b66b3.

The Ruby source gem includes this MIT-licensed crate so codec fixes are present
when users build it without a separate unpublished dependency.

- Decode BIGNUM's binary payload as bytes, rather than UTF-8. The Ruby bridge
  converts its sign/magnitude encoding to an arbitrary-precision Integer.
- Recognize DuckDB 2.0 TIMESTAMPTZ_NS (logical ID 33) and TUPLE (ID 110).
- Keep unnamed STRUCT/TUPLE fields by ordinal, rather than overwriting every
  empty-name field in an IndexMap. Encoding and append normalization use the
  same ordinal keys. UNION's empty-name tag field remains unchanged.

Real protocol integration coverage lives in the Ruby test suite.
