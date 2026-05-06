# UniTweet 
### A University Social Media Platform

UniTweet is a text-only social media platform built exclusively 
for university students, inspired by X (formerly Twitter). 
Students can post tweets, like, reply, follow each other, send 
direct messages, search for users and tweets, and explore 
trending content — all in a clean desktop interface. Admin 
accounts can monitor and moderate reported content through a 
dedicated dashboard.

---

## 👥 Team Members

| Name |
|------|
| Muhammad Ahmad Sajid |
| Muhammad Taha |
| Mohsin Saeed |

**Course:** Database Systems
**Semester:** Spring 2025

---

## 📌 Project Description

UniTweet is designed specifically for university students. Every 
student already has an account pre-loaded with their university 
data (registration number, name, department, batch year). 
Students activate their account by setting a password on first 
login. The platform is text-only — no images, audio, or video 
of any kind — keeping the focus on ideas and discussion.

---

## ✨ Features

### For Students
- **Post Tweets** — Share text posts up to 280 characters
- **Like Tweets** — Like and unlike any tweet
- **Reply to Tweets** — Threaded replies with nested comments
- **Follow / Unfollow** — Follow other students to build your feed
- **Home Feed** — See tweets from people you follow, newest first
- **Trending Feed** — Discover the most liked tweets from the 
  last 7 days
- **Direct Messages** — Private text conversations with any student
- **Search** — Search for students by name, reg no, or department.
  Search tweets by keyword
- **Profile Page** — View any student's profile, tweet history,
  follower and following counts
- **Report Content** — Report tweets that violate community 
  guidelines

### For Admins
- **Moderation Dashboard** — View all pending reports
- **Delete Reported Posts** — Soft-delete violating tweets
- **Dismiss Reports** — Dismiss false or invalid reports
- **Bulk Dismiss** — Dismiss all reports older than N days at once

---

## 🛠️ Technology Stack

| Layer | Technology |
|-------|-----------|
| Database | PostgreSQL 16 |
| DB Admin Tool | pgAdmin 4 |
| Backend / DB Layer | Python 3 + psycopg2 |
| Frontend | Python 3 + Tkinter |
| Password Security | bcrypt |
| Full-Text Search | PostgreSQL GIN + tsvector |
| Fuzzy Search | PostgreSQL pg_trgm extension |

---

## 🗄️ Database Design

The database contains 8 tables:

| Table | Purpose |
|-------|---------|
| users | All university students |
| admins | Admin accounts |
| tweets | Text posts (280 char max) |
| likes | Which student liked which tweet |
| replies | Threaded comments on tweets |
| follows | Follow relationships between students |
| direct_messages | Private messages between students |
| reports | User-submitted content reports |

### Normalization
All tables are normalized to **Third Normal Form (3NF)**:
- **1NF** — Every column holds one atomic value per row
- **2NF** — No partial dependencies on composite keys
- **3NF** — No transitive dependencies between non-key columns

### Views (6)
- `vw_tweet_details` — Tweets with author information
- `vw_trending_tweets` — Top liked tweets from last 7 days
- `vw_user_stats` — User profiles with counts
- `vw_reply_details` — Replies with author information
- `vw_pending_reports` — Admin moderation view
- `vw_inbox_summary` — Latest message per conversation

### Triggers (9)
- Auto increment / decrement like and reply counts
- Prevent self-like, self-follow, self-message
- Auto set updated_at timestamp on tweet edits
- Cascade soft-delete replies when tweet is deleted

### Indexes (12)
- B-Tree indexes on all foreign keys, timestamps, and counters
- GIN indexes for full-text and fuzzy search

### Cursors (3)
- `generate_user_report` — Row-by-row tweet statistics
- `admin_bulk_dismiss` — Batch dismiss old reports
- `build_home_digest` — Build text digest of home feed

### Functions (24)
Stored functions covering authentication, tweets, feeds, 
likes, replies, follows, direct messages, search, and 
admin moderation.

### Transactions
All multi-step operations (toggle like, add reply, resolve 
report) are wrapped in transactions to guarantee data 
integrity.

---

## 📁 Project Structure
UniTweet/
│
├── app.py              # Tkinter frontend — all 11 screens
├── db.py               # PostgreSQL connection layer
├── seed_test.py        # Automated testing script
├── README.md           # This file
│
└── sql/
## 🖥️ Application Screens

| Screen | Description |
|--------|-------------|
| Login | Sign in with reg no or email + password |
| Register | New student account setup |
| Home Feed | Tweets from followed students, newest first |
| Trending Feed | Most liked tweets from last 7 days |
| Compose Tweet | Write and post a new tweet (280 char limit) |
| Profile | Student profile with stats and tweet history |
| Tweet Detail | Full tweet with threaded reply tree |
| Search | Find students and tweets by keyword |
| Inbox | List of all direct message conversations |
| Conversation | Chat-style message view with send box |
| Admin Panel | Moderation dashboard (admin accounts only) |

---

## 🔐 Security

- All passwords hashed with **bcrypt** before storage
- Passwords are never stored or transmitted in plain text
- Self-like, self-follow, and self-message blocked at 
  database level by triggers
- Soft deletes used throughout — no data is permanently 
  destroyed
- Admin panel only accessible to admin accounts

---

## 🧪 Testing

Run the automated test script to verify all features work:
python seed_test.py
This tests 13 flows including register, login, tweet, 
like, follow, feed, search, messaging, and reporting.

---

## 📝 License

This project was built for academic purposes as part of 
the Database Systems course.

1. requirements.txt
Tells anyone who downloads your project exactly what to install.
psycopg2-binary
bcrypt
Just create a file called requirements.txt and paste those 2 lines. Then anyone can run:
pip install -r requirements.txt

2. .gitignore
Prevents accidentally uploading sensitive files to GitHub.
__pycache__/
*.pyc
*.pyo
.env
db_config.py

