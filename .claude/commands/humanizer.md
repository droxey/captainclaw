---
name: humanizer
version: 2.3.0
description: |
  Remove signs of AI-generated writing from text. Use when editing or reviewing
  text to make it sound more natural and human-written. Based on Wikipedia's
  comprehensive "Signs of AI writing" guide. Detects and fixes patterns including:
  inflated symbolism, promotional language, superficial -ing analyses, vague
  attributions, em dash overuse, rule of three, AI vocabulary words, negative
  parallelisms, and excessive conjunctive phrases.
  Do not use for technical documentation, API references, or code comments
  where neutral tone is expected.
allowed-tools:
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - AskUserQuestion
---

# Humanizer: Remove AI Writing Patterns

Identify and remove signs of AI-generated text to make writing sound natural and human. Based on Wikipedia's "Signs of AI writing" page, maintained by WikiProject AI Cleanup.

## Procedure

1. Scan the input text for the AI patterns listed in the checklist below.
2. Rewrite problematic sections, replacing AI patterns with natural alternatives.
3. Preserve the core meaning of the original text.
4. Match the intended tone (formal, casual, technical, etc.).
5. Add personality — sterile, voiceless writing is just as obvious as slop. See the guidance below.
6. Present a draft rewrite.
7. Run an anti-AI audit: ask "What makes the below so obviously AI generated?" and list remaining tells.
8. Revise the draft to eliminate remaining tells. Present the final version.

---

## Personality and soul

Removing AI patterns is only half the job. Good writing has a human behind it.

**Signs of soulless writing (even if technically "clean"):**
- Every sentence is the same length and structure
- No opinions, just neutral reporting
- No acknowledgment of uncertainty or mixed feelings
- No first-person perspective when appropriate
- No humor, no edge, no personality
- Reads like a Wikipedia article or press release

**How to add voice:**
- **Have opinions.** React to facts instead of neutrally listing them.
- **Vary rhythm.** Mix short punchy sentences with longer ones.
- **Acknowledge complexity.** "This is impressive but also kind of unsettling" beats "This is impressive."
- **Use "I" when it fits.** First person is honest, not unprofessional.
- **Let some mess in.** Perfect structure feels algorithmic.
- **Be specific about feelings.** Not "this is concerning" but concrete descriptions.

---

## AI pattern checklist

Scan for these 24 patterns:

**Content patterns:**
1. Undue emphasis on significance, legacy, and broader trends
2. Undue emphasis on notability and media coverage
3. Superficial analyses with -ing endings
4. Promotional and advertisement-like language
5. Vague attributions and weasel words
6. Outline-like "Challenges and Future Prospects" sections

**Language and grammar patterns:**
7. Overused "AI vocabulary" words (delve, landscape, tapestry, foster, underscore, etc.)
8. Avoidance of "is"/"are" (copula avoidance — "serves as", "stands as")
9. Negative parallelisms ("It's not just about X; it's Y")
10. Rule of three overuse
11. Elegant variation (synonym cycling)
12. False ranges ("from X to Y" on meaningless scales)

**Style patterns:**
13. Em dash overuse
14. Overuse of boldface
15. Inline-header vertical lists
16. Title case in headings
17. Emojis in headings or bullet points
18. Curly quotation marks

**Communication patterns:**
19. Collaborative communication artifacts ("I hope this helps!", "Let me know")
20. Knowledge-cutoff disclaimers ("as of [date]", "based on available information")
21. Sycophantic/servile tone ("Great question!", "You're absolutely right!")

**Filler and hedging:**
22. Filler phrases ("In order to", "It is important to note that")
23. Excessive hedging ("could potentially possibly be argued")
24. Generic positive conclusions ("the future looks bright")

---

## Output format

1. Draft rewrite
2. Anti-AI audit: "What makes the below so obviously AI generated?" (brief bullets)
3. Final rewrite
4. Summary of changes made (optional)

---

## Reference

Based on [Wikipedia:Signs of AI writing](https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing), maintained by WikiProject AI Cleanup. "LLMs use statistical algorithms to guess what should come next. The result tends toward the most statistically likely result that applies to the widest variety of cases."
