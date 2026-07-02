# Compliance Radar: Requirements

**Author:** Shivansh Chauhan
**Version:** 0.1
**Date:** 2 July 2026

## Business context

Firms that vet UK companies, such as audit firms, lenders, and client onboarding teams, need to spot early signs of financial distress before they commit. Today that work is slow and manual. An analyst checks Companies House, then public filings, then the news, one company at a time, and builds the picture by hand. Warning signs like a late filing, a sudden change of directors, or a strike-off notice get caught late, if they are caught at all.

## Who this is for

The main user is a business intelligence or financial analyst. The person they report to is a Head of Compliance or a Client Onboarding Manager. What they want is simple: show me, in a few minutes, which companies out of the thousands we track actually need a person to look at them this week.

## Objective

Build an automated pipeline that pulls Companies House data, applies clear risk rules and AI extraction, and produces a ranked watchlist. Analysts then spend their time on the small group that scores highest, instead of reviewing every company.

## What it does (deliverables)

- Ingests the bulk Companies House register into a structured warehouse built on a star schema.
- Enriches a chosen set of companies through the Companies House API, with throttling to respect the rate limit.
- Applies transparent risk flags to each company (see `risk-flags.md`).
- Adds AI-extracted flags from the text of company accounts.
- Serves the results through a Power BI dashboard and a plain-English query and chat layer (RAG plus an agent).
- Measures the AI layer with an evaluation harness (see `EVALUATION.md`).

## What it does not do (out of scope)

- It does not make decisions or take any action on a company. It is read only, and it supports a human decision rather than replacing it.
- It does not monitor in real time. Data refreshes on a schedule.
- It does not cover companies outside the UK.

## How I will know it works (success criteria)

- The pipeline runs end to end, from the raw download through to the gold tables.
- Every risk flag can be traced back to a rule or a source, so a reviewer can check why a company was flagged.
- The AI layer meets the quality targets set in `EVALUATION.md`, such as extraction recall, answer faithfulness, and a low hallucination rate.
- A modelled estimate of analyst time saved, with the assumptions written down next to the number.

## Data sources

- Free Company Data Product, the bulk snapshot of roughly five million companies.
- Companies House REST API, for live officers, filings, and persons with significant control.
- PSC data product, for ownership and control.

## Assumptions and limits

- This is a portfolio project with no real client, so any business impact figure is illustrative and is labelled that way.
- Director records are personal data. Anything published, such as screenshots or a demo video, uses synthetic or redacted data only.
- The API is rate limited, so live enrichment covers a subset of companies rather than the whole register.
- The bulk snapshot can be up to a month old. Live facts come from the API at the time of review.

## Definition of done

A public repository with a working pipeline, both rule-based and AI flags, a dashboard, a populated `EVALUATION.md`, and a one-page case study, all built on data that is safe to publish.