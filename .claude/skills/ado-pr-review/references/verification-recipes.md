# Domain-specific verification recipes

`review-pr.md` Step 5.5 verifies each finding against the PR's source tree before posting. A naive
`git grep` is fine for most claims, but some stacks store or reference identifiers in ways that make a
plain grep produce false positives ("symbol X is missing!" when it is right there in a different
casing) or false negatives. Record those rules here so the verifier applies them. Add your own; delete
the example if it does not apply to you.

## Why this exists

The verifier's job is to answer testable hypotheses like "is symbol Y actually defined on this
branch?" with `git grep`. If your codebase's identity format is not what the grep literally searches
for, the answer comes back wrong and the bot posts (or drops) the finding incorrectly. A one-line
normalization rule fixes a whole class of false positives.

## Example recipe: CMS GUID casing (Sitecore-style serialized content)

Some headless CMS platforms serialize content items to files where the item's **defining** ID and its
**references** use different formats:

- The item declares its own id lowercase, unbraced: `ID: "024e08da-e5e3-47c1-9827-d0fdfedad263"`
- Other items reference it uppercase, braced: `{024E08DA-E5E3-47C1-9827-D0FDFEDAD263}`

A case-sensitive grep for the braced form will **miss the defining item** and the bot will wrongly
flag "GUID referenced but not introduced." Normalize before grepping - strip braces, lowercase, and
use `-i`:

```powershell
function Normalize-CmsId([string] $id) { return $id.Trim('{','}').Trim().ToLower() }
$probe = Normalize-CmsId '{024E08DA-E5E3-47C1-9827-D0FDFEDAD263}'   # -> '024e08da-...'
$hits  = & git grep -li $probe $headSha -- "path/to/serialized/content" 2>$null
```

Rule of thumb: for any ID-existence check on serialized CMS/ORM content, normalize both the probe and
match case-insensitively before concluding "not found."

## Template for a new recipe

```
### <Stack / format name>

When the bot sees a finding of shape: <e.g. "entity X referenced but not defined">
The naive check fails because: <e.g. entities are declared via a decorator in a separate registry file>
Do this instead: <the corrected git grep / git show pattern, with $headSha>
```

Keep recipes short and specific. Each one should turn a recurring false positive into a reliable
verification.
