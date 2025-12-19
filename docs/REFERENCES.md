# References & Further Reading

This document collects **publicly available references** related to Anaconda’s
licensing changes, commercial usage policies, and the community-driven migration
towards conda-forge / Miniforge.

The purpose of this list is **information verification**, not legal interpretation.

---

## 1. Anaconda Official Policies & Statements

### Anaconda Terms of Service / Licensing

- Anaconda Terms of Service  
  https://www.anaconda.com/terms-of-service

- Anaconda Licensing FAQ  
  https://www.anaconda.com/pricing/terms-of-service-faq

Key points commonly referenced:
- Commercial usage threshold based on organization size (e.g. >200 employees)
- Distinction between Anaconda Distribution, Miniconda, and third-party channels
- Commercial licensing requirements tied to Anaconda-provided repositories

---

### Academic & Non-Profit Policies

- Anaconda for Education  
  https://www.anaconda.com/education

- Academic / Non-Profit usage explanations (policy pages & blog posts)  
  https://www.anaconda.com/blog

> Note: Policy wording has changed over time. Always refer to the **latest**
> official documentation for authoritative definitions.

---

## 2. Miniconda, Miniforge, and conda-forge

### Miniconda

- Miniconda documentation  
  https://docs.conda.io/en/latest/miniconda.html

Important note:
- Miniconda **defaults to the Anaconda `defaults` channel**, which may be subject
  to Anaconda’s Terms of Service.

---

### Miniforge / Mambaforge

- Miniforge GitHub Repository  
  https://github.com/conda-forge/miniforge

- conda-forge official site  
  https://conda-forge.org/

Key characteristics:
- Community-maintained
- Defaults to `conda-forge` channel
- Not distributed by Anaconda
- Widely adopted as a drop-in replacement for Miniconda/Anaconda

---

## 3. Community Discussions & Industry Responses

> These links reflect **community reactions and interpretations**, not official policy.

- Reddit / Hacker News discussions on Anaconda licensing changes  
  (search keywords: "Anaconda license 200 employees", "Anaconda Miniforge migration")

- Blog posts explaining migration away from Anaconda defaults  
  Examples:
  - “Why we switched from Anaconda to conda-forge”
  - “Miniforge as a safe alternative to Miniconda”

---

## 4. Industry Migration Examples

- AWS public documentation and container images referencing conda-forge
- Enterprise ML/DL base images replacing Anaconda channels with conda-forge
- Open-source projects recommending Miniforge in installation guides

These examples indicate **ecosystem-level adoption**, not legal endorsement.

---

## 5. Disclaimer

All references listed here are:
- Publicly accessible
- Provided for educational and verification purposes only

This project does **not** claim legal authority over Anaconda’s licensing,
nor does it provide legal advice.

If you are subject to compliance reviews or legal notices, consult:
- Official Anaconda documentation
- Qualified legal counsel