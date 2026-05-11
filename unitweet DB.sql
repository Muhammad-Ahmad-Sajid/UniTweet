-- ==========================================
-- Users Table
-- ==========================================
CREATE TABLE users (
    reg_no VARCHAR(20) PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    batch_year INTEGER NOT NULL CHECK (batch_year >= 1900),
    department VARCHAR(100) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ==========================================
-- Admins Table
-- ==========================================
CREATE TABLE admins (
    admin_id SERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ==========================================
-- Tweets Table
-- ==========================================
CREATE TABLE tweets (
    tweet_id SERIAL PRIMARY KEY,
    author_reg_no VARCHAR(20) NOT NULL REFERENCES users(reg_no) ON DELETE CASCADE,
    content TEXT NOT NULL CHECK (char_length(content) > 0 AND char_length(content) <= 280),
    is_deleted BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ==========================================
-- Replies Table (Threaded Comments)
-- ==========================================
CREATE TABLE replies (
    reply_id SERIAL PRIMARY KEY,
    tweet_id INTEGER NOT NULL REFERENCES tweets(tweet_id) ON DELETE CASCADE,
    author_reg_no VARCHAR(20) NOT NULL REFERENCES users(reg_no) ON DELETE CASCADE,
    parent_reply_id INTEGER REFERENCES replies(reply_id) ON DELETE CASCADE, -- Allows for nested threaded replies
    content TEXT NOT NULL CHECK (char_length(content) > 0 AND char_length(content) <= 280),
    is_deleted BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ==========================================
-- Likes Table
-- ==========================================
CREATE TABLE likes (
    like_id SERIAL PRIMARY KEY,
    tweet_id INTEGER NOT NULL REFERENCES tweets(tweet_id) ON DELETE CASCADE,
    user_reg_no VARCHAR(20) NOT NULL REFERENCES users(reg_no) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(tweet_id, user_reg_no) -- Prevents a user from liking the same tweet multiple times
);

-- ==========================================
-- Follows Table
-- ==========================================
CREATE TABLE follows (
    follower_reg_no VARCHAR(20) NOT NULL REFERENCES users(reg_no) ON DELETE CASCADE,
    following_reg_no VARCHAR(20) NOT NULL REFERENCES users(reg_no) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (follower_reg_no, following_reg_no),
    CHECK (follower_reg_no != following_reg_no) -- Prevents users from following themselves
);

-- ==========================================
-- Direct Messages Table
-- ==========================================
CREATE TABLE direct_messages (
    message_id SERIAL PRIMARY KEY,
    sender_reg_no VARCHAR(20) NOT NULL REFERENCES users(reg_no) ON DELETE CASCADE,
    receiver_reg_no VARCHAR(20) NOT NULL REFERENCES users(reg_no) ON DELETE CASCADE,
    content TEXT NOT NULL CHECK (char_length(content) > 0),
    is_deleted BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CHECK (sender_reg_no != receiver_reg_no) -- Prevents users from messaging themselves
);

-- ==========================================
-- Reports Table (Admin Moderation)
-- ==========================================
CREATE TABLE reports (
    report_id SERIAL PRIMARY KEY,
    reporter_reg_no VARCHAR(20) NOT NULL REFERENCES users(reg_no) ON DELETE CASCADE,
    reported_tweet_id INTEGER REFERENCES tweets(tweet_id) ON DELETE CASCADE,
    reported_user_reg_no VARCHAR(20) REFERENCES users(reg_no) ON DELETE CASCADE,
    reason TEXT NOT NULL,
    status VARCHAR(20) DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'REVIEWED', 'RESOLVED')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CHECK (
        (reported_tweet_id IS NOT NULL AND reported_user_reg_no IS NULL) OR 
        (reported_tweet_id IS NULL AND reported_user_reg_no IS NOT NULL)
    ) -- Ensures that a report is either for a tweet OR a user, not both or neither
);
Enable the pg_trgm extension required for the trigram-based GIN index
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- The previous schema did not include a 'like_count' column. We need to add it 
-- to the tweets table first so we can index it for the trending feed.
ALTER TABLE tweets ADD COLUMN IF NOT EXISTS like_count INTEGER DEFAULT 0;

-- ==========================================
-- B-TREE INDEXES
-- ==========================================

-- Speeds up fetching a specific user's timeline/profile (finding all tweets by one author)
CREATE INDEX idx_tweets_user_id ON tweets(author_reg_no);

-- Speeds up loading the chronological timeline/feed (showing the latest tweets first)
CREATE INDEX idx_tweets_created_at ON tweets(created_at DESC);

-- Speeds up generating the trending feed by quickly sorting tweets by highest likes
CREATE INDEX idx_tweets_like_count ON tweets(like_count DESC);

-- Speeds up counting likes for a specific tweet or checking who liked a specific tweet
CREATE INDEX idx_likes_tweet_id ON likes(tweet_id);

-- Speeds up finding all users that a specific person is following (their "following" list)
CREATE INDEX idx_follows_follower ON follows(follower_reg_no);

-- Speeds up finding all followers of a specific user (their "followers" list)
CREATE INDEX idx_follows_followee ON follows(following_reg_no);

-- Speeds up looking up a user by their exact registration number.
-- (Note: PostgreSQL automatically creates an index for Primary Keys, but adding it explicitly as requested)
CREATE INDEX idx_users_reg_no ON users(reg_no);

-- Speeds up looking up a user during login or registration by exact email.
-- (Note: PostgreSQL automatically creates an index for UNIQUE constraints, but adding it explicitly as requested)
CREATE INDEX idx_users_email ON users(email);

-- Speeds up the admin dashboard when filtering reports by their status (e.g., fetching all 'PENDING' reports)
CREATE INDEX idx_reports_status ON reports(status);

-- Speeds up fetching the chat history between two specific users in Direct Messages
CREATE INDEX idx_dm_participants ON direct_messages(sender_reg_no, receiver_reg_no);

-- ==========================================
-- GIN INDEXES (Generalized Inverted Index)
-- ==========================================

-- Enables fast Full Text Search (FTS) on tweet content, allowing users to efficiently search for specific keywords
CREATE INDEX idx_tweets_fts ON tweets USING GIN (to_tsvector('english', content));

-- Enables fast partial-string / fuzzy search on user names (e.g., typing "ahm" will quickly find "Ahmad")
CREATE INDEX idx_users_name_trgm ON users USING GIN (full_name gin_trgm_ops);
==========================================
1. vw_tweet_details
Combines tweet data with the author's profile info and calculates the reply count dynamically.
Useful for rendering the main feed where you need both the tweet and the author's details.
==========================================
CREATE OR REPLACE VIEW vw_tweet_details AS
SELECT 
    t.tweet_id,
    t.content,
    t.like_count,
    (SELECT COUNT(*) FROM replies r WHERE r.tweet_id = t.tweet_id AND r.is_deleted = FALSE) AS reply_count,
    t.created_at,
    u.reg_no AS user_id, -- Aliased as user_id as requested
    u.reg_no,
    u.full_name,
    u.department
FROM tweets t
JOIN users u ON t.author_reg_no = u.reg_no
WHERE t.is_deleted = FALSE;

-- ==========================================
-- 2. vw_trending_tweets
-- Fetches the most popular tweets from the last 7 days based on likes.
-- This view builds directly on top of vw_tweet_details to reuse its JOIN logic.
-- ==========================================
CREATE OR REPLACE VIEW vw_trending_tweets AS
SELECT *
FROM vw_tweet_details
WHERE created_at >= NOW() - INTERVAL '7 days'
ORDER BY like_count DESC;

-- ==========================================
-- 3. vw_user_stats
-- Generates a complete profile overview for a user, calculating how many tweets they've made,
-- how many people follow them, and how many people they are following.
-- ==========================================
CREATE OR REPLACE VIEW vw_user_stats AS
SELECT 
    u.reg_no,
    u.full_name,
    u.email,
    u.department,
    u.batch_year,
    (SELECT COUNT(*) FROM tweets t WHERE t.author_reg_no = u.reg_no AND t.is_deleted = FALSE) AS tweet_count,
    (SELECT COUNT(*) FROM follows f WHERE f.following_reg_no = u.reg_no) AS follower_count,
    (SELECT COUNT(*) FROM follows f WHERE f.follower_reg_no = u.reg_no) AS following_count
FROM users u;

-- ==========================================
-- 4. vw_reply_details
-- Combines reply data with the replying user's profile info.
-- Useful for rendering the comment section under a specific tweet.
-- ==========================================
CREATE OR REPLACE VIEW vw_reply_details AS
SELECT 
    r.reply_id,
    r.tweet_id,
    r.parent_reply_id,
    r.content,
    r.created_at,
    u.reg_no AS author_reg_no,
    u.full_name AS author_name
FROM replies r
JOIN users u ON r.author_reg_no = u.reg_no
WHERE r.is_deleted = FALSE;

-- ==========================================
-- 5. vw_pending_reports
-- Specifically tailored for the Admin Dashboard to review reports that need attention.
-- Uses LEFT JOINs so it works whether a User OR a Tweet was reported.
-- ==========================================
CREATE OR REPLACE VIEW vw_pending_reports AS
SELECT 
    rep.report_id,
    rep.reason,
    rep.created_at AS report_date,
    rep.reporter_reg_no,
    u.full_name AS reporter_name,
    rep.reported_tweet_id,
    LEFT(t.content, 50) AS tweet_preview, -- Takes the first 50 chars of the tweet as a preview
    rep.reported_user_reg_no,
    ru.full_name AS reported_user_name
FROM reports rep
JOIN users u ON rep.reporter_reg_no = u.reg_no
LEFT JOIN tweets t ON rep.reported_tweet_id = t.tweet_id
LEFT JOIN users ru ON rep.reported_user_reg_no = ru.reg_no
WHERE rep.status = 'PENDING';

-- ==========================================
-- 6. vw_inbox_summary
-- Generates the "Inbox" view for a user, showing one row per conversation partner 
-- along with the text and timestamp of their most recent message exchanged.
-- Uses DISTINCT ON to grab only the latest message per thread.
-- ==========================================
CREATE OR REPLACE VIEW vw_inbox_summary AS
WITH conversation_messages AS (
    -- Get messages where the user is the sender
    SELECT 
        sender_reg_no AS user_reg_no, 
        receiver_reg_no AS partner_reg_no, 
        content, 
        created_at
    FROM direct_messages
    WHERE is_deleted = FALSE
    UNION ALL
    -- Get messages where the user is the receiver
    SELECT 
        receiver_reg_no AS user_reg_no, 
        sender_reg_no AS partner_reg_no, 
        content, 
        created_at
    FROM direct_messages
    WHERE is_deleted = FALSE
)
SELECT DISTINCT ON (user_reg_no, partner_reg_no)
    user_reg_no,
    partner_reg_no,
    content AS latest_message,
    created_at AS message_time
FROM conversation_messages
ORDER BY user_reg_no, partner_reg_no, created_at DESC;
First, add the necessary columns to the tweets table if they don't exist yet
ALTER TABLE tweets ADD COLUMN IF NOT EXISTS reply_count INTEGER DEFAULT 0;
ALTER TABLE tweets ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

-- ==========================================
-- 1. trg_increment_like_count
-- Automatically increases the like_count on a tweet when someone likes it
-- ==========================================
CREATE OR REPLACE FUNCTION fn_increment_like_count() RETURNS TRIGGER AS $$
BEGIN
    UPDATE tweets SET like_count = like_count + 1 WHERE tweet_id = NEW.tweet_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_increment_like_count
AFTER INSERT ON likes
FOR EACH ROW
EXECUTE FUNCTION fn_increment_like_count();

-- ==========================================
-- 2. trg_decrement_like_count
-- Automatically decreases the like_count on a tweet when someone unlikes it.
-- Uses GREATEST to ensure it never drops below 0.
-- ==========================================
CREATE OR REPLACE FUNCTION fn_decrement_like_count() RETURNS TRIGGER AS $$
BEGIN
    UPDATE tweets SET like_count = GREATEST(like_count - 1, 0) WHERE tweet_id = OLD.tweet_id;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_decrement_like_count
AFTER DELETE ON likes
FOR EACH ROW
EXECUTE FUNCTION fn_decrement_like_count();

-- ==========================================
-- 3. trg_increment_reply_count
-- Automatically increases the reply_count on a tweet when a new reply is posted
-- ==========================================
CREATE OR REPLACE FUNCTION fn_increment_reply_count() RETURNS TRIGGER AS $$
BEGIN
    UPDATE tweets SET reply_count = reply_count + 1 WHERE tweet_id = NEW.tweet_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_increment_reply_count
AFTER INSERT ON replies
FOR EACH ROW
EXECUTE FUNCTION fn_increment_reply_count();

-- ==========================================
-- 4. trg_decrement_reply_count
-- Automatically decreases the reply_count when a reply is "soft deleted".
-- ==========================================
CREATE OR REPLACE FUNCTION fn_decrement_reply_count() RETURNS TRIGGER AS $$
BEGIN
    UPDATE tweets SET reply_count = GREATEST(reply_count - 1, 0) WHERE tweet_id = NEW.tweet_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_decrement_reply_count
AFTER UPDATE ON replies
FOR EACH ROW
WHEN (OLD.is_deleted = FALSE AND NEW.is_deleted = TRUE)
EXECUTE FUNCTION fn_decrement_reply_count();

-- ==========================================
-- 5. trg_prevent_self_like
-- Throws a custom error if a user attempts to like their own tweet
-- ==========================================
CREATE OR REPLACE FUNCTION fn_prevent_self_like() RETURNS TRIGGER AS $$
DECLARE
    tweet_author VARCHAR(20);
BEGIN
    -- Fetch the author of the tweet being liked
    SELECT author_reg_no INTO tweet_author FROM tweets WHERE tweet_id = NEW.tweet_id;
    
    IF NEW.user_reg_no = tweet_author THEN
        RAISE EXCEPTION 'Users cannot like their own tweets.';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prevent_self_like
BEFORE INSERT ON likes
FOR EACH ROW
EXECUTE FUNCTION fn_prevent_self_like();

-- ==========================================
-- 6. trg_prevent_self_follow
-- Throws a custom error if a user attempts to follow themselves
-- (Acts as a companion to our existing CHECK constraint for better error messages)
-- ==========================================
CREATE OR REPLACE FUNCTION fn_prevent_self_follow() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.follower_reg_no = NEW.following_reg_no THEN
        RAISE EXCEPTION 'Users cannot follow themselves.';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prevent_self_follow
BEFORE INSERT ON follows
FOR EACH ROW
EXECUTE FUNCTION fn_prevent_self_follow();

-- ==========================================
-- 7. trg_prevent_self_dm
-- Throws a custom error if a user attempts to send a DM to themselves
-- (Acts as a companion to our existing CHECK constraint for better error messages)
-- ==========================================
CREATE OR REPLACE FUNCTION fn_prevent_self_dm() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.sender_reg_no = NEW.receiver_reg_no THEN
        RAISE EXCEPTION 'Users cannot send direct messages to themselves.';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prevent_self_dm
BEFORE INSERT ON direct_messages
FOR EACH ROW
EXECUTE FUNCTION fn_prevent_self_dm();

-- ==========================================
-- 8. trg_tweet_updated_at
-- Automatically updates the updated_at timestamp whenever a tweet's content is modified
-- ==========================================
CREATE OR REPLACE FUNCTION fn_tweet_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_tweet_updated_at
BEFORE UPDATE ON tweets
FOR EACH ROW
EXECUTE FUNCTION fn_tweet_updated_at();

-- ==========================================
-- 9. trg_cascade_delete_replies
-- When a main tweet is soft deleted, automatically soft delete all of its replies
-- ==========================================
CREATE OR REPLACE FUNCTION fn_cascade_delete_replies() RETURNS TRIGGER AS $$
BEGIN
    UPDATE replies SET is_deleted = TRUE WHERE tweet_id = NEW.tweet_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_cascade_delete_replies
AFTER UPDATE ON tweets
FOR EACH ROW
WHEN (OLD.is_deleted = FALSE AND NEW.is_deleted = TRUE)
EXECUTE FUNCTION fn_cascade_delete_replies();
Update the constraint on the reports table to allow the 'DISMISSED' status
ALTER TABLE reports DROP CONSTRAINT reports_status_check;
ALTER TABLE reports ADD CONSTRAINT reports_status_check 
    CHECK (status IN ('PENDING', 'REVIEWED', 'RESOLVED', 'DISMISSED'));

-- ==========================================
-- 1. generate_user_report
-- Calculates total tweets, likes, and replies for a single user using a cursor
-- ==========================================
CREATE OR REPLACE FUNCTION generate_user_report(p_user_id VARCHAR) 
RETURNS TABLE(tweet_count INT, total_likes INT, total_replies INT) AS $$
DECLARE
    -- 1. DECLARE the cursor
    cur_tweets CURSOR FOR 
        SELECT tweet_id, like_count, reply_count 
        FROM tweets 
        WHERE author_reg_no = p_user_id AND is_deleted = FALSE;
        
    -- Variables to hold fetched row data
    v_tweet_id INT;
    v_like_count INT;
    v_reply_count INT;
    
    -- Accumulator variables
    v_total_tweets INT := 0;
    v_total_likes_acc INT := 0;
    v_total_replies_acc INT := 0;
BEGIN
    -- 2. OPEN the cursor
    OPEN cur_tweets;
    
    LOOP
        -- 3. FETCH the next row
        FETCH cur_tweets INTO v_tweet_id, v_like_count, v_reply_count;
        
        -- EXIT loop when no more rows are found
        EXIT WHEN NOT FOUND;
        
        -- Accumulate the counts
        v_total_tweets := v_total_tweets + 1;
        v_total_likes_acc := v_total_likes_acc + v_like_count;
        v_total_replies_acc := v_total_replies_acc + v_reply_count;
    END LOOP;
    
    -- 4. CLOSE the cursor
    CLOSE cur_tweets;
    
    -- Return the accumulated results as a table row
    RETURN QUERY SELECT v_total_tweets, v_total_likes_acc, v_total_replies_acc;
END;
$$ LANGUAGE plpgsql;

-- ==========================================
-- 2. admin_bulk_dismiss
-- Dismisses old PENDING reports and returns the number of reports dismissed
-- ==========================================
CREATE OR REPLACE FUNCTION admin_bulk_dismiss(p_days_old INT, p_admin_id INT) 
RETURNS INT AS $$
DECLARE
    -- 1. DECLARE the cursor
    cur_reports CURSOR FOR 
        SELECT report_id 
        FROM reports 
        WHERE status = 'PENDING' 
        AND created_at < NOW() - (p_days_old || ' days')::INTERVAL;
        
    v_report_id INT;
    v_dismissed_count INT := 0;
BEGIN
    -- Note: p_admin_id is passed in, but since our reports table doesn't currently 
    -- store WHICH admin resolved it, we don't save it. If you add an 'admin_id' 
    -- column to reports later, you would include it in the UPDATE statement below.

    -- 2. OPEN the cursor
    OPEN cur_reports;
    
    LOOP
        -- 3. FETCH the next row
        FETCH cur_reports INTO v_report_id;
        
        -- EXIT loop when no more rows are found
        EXIT WHEN NOT FOUND;
        
        -- Update the specific report
        UPDATE reports 
        SET status = 'DISMISSED' 
        WHERE report_id = v_report_id;
        
        -- Increment our counter
        v_dismissed_count := v_dismissed_count + 1;
    END LOOP;
    
    -- 4. CLOSE the cursor
    CLOSE cur_reports;
    
    -- Return the total number of reports dismissed
    RETURN v_dismissed_count;
END;
$$ LANGUAGE plpgsql;

-- ==========================================
-- 3. build_home_digest
-- Assembles a text digest of the latest 10 tweets from users the target user follows
-- ==========================================
CREATE OR REPLACE FUNCTION build_home_digest(p_user_id VARCHAR) 
RETURNS TEXT AS $$
DECLARE
    -- 1. DECLARE the cursor
    -- Joins vw_tweet_details with the follows table
    cur_digest CURSOR FOR 
        SELECT content, full_name 
        FROM vw_tweet_details 
        WHERE user_id IN (
            SELECT following_reg_no 
            FROM follows 
            WHERE follower_reg_no = p_user_id
        ) 
        ORDER BY created_at DESC 
        LIMIT 10;
        
    v_content TEXT;
    v_full_name VARCHAR;
    v_digest_text TEXT := '';
BEGIN
    -- 2. OPEN the cursor
    OPEN cur_digest;
    
    LOOP
        -- 3. FETCH the next row
        FETCH cur_digest INTO v_content, v_full_name;
        
        -- EXIT loop when no more rows are found
        EXIT WHEN NOT FOUND;
        
        -- Concatenate into a text summary string
        -- (chr(10) adds a newline for readability in text-only UIs)
        v_digest_text := v_digest_text || v_full_name || ': "' || v_content || '"' || chr(10);
    END LOOP;
    
    -- 4. CLOSE the cursor
    CLOSE cur_digest;
    
    -- If the digest is completely empty, provide a default fallback message
    IF v_digest_text = '' THEN
        v_digest_text := 'Your timeline is empty. Follow some users to see their tweets here!';
    END IF;
    
    -- Return the assembled digest text
    RETURN v_digest_text;
END;
$$ LANGUAGE plpgsql;
Ensure the users table has a password_hash column for the auth functions
ALTER TABLE users ADD COLUMN IF NOT EXISTS password_hash TEXT;

-- ==========================================
-- AUTH & USERS
-- ==========================================

-- 1. register_user
-- Inserts a new user into the database
CREATE OR REPLACE FUNCTION register_user(
    p_reg_no VARCHAR, p_full_name VARCHAR, p_email VARCHAR, 
    p_password_hash TEXT, p_batch_year INT, p_department VARCHAR
) RETURNS void AS $$
BEGIN
    INSERT INTO users (reg_no, full_name, email, password_hash, batch_year, department)
    VALUES (p_reg_no, p_full_name, p_email, p_password_hash, p_batch_year, p_department);
END;
$$ LANGUAGE plpgsql;

-- 2. get_user_for_login
-- Fetches user credentials allowing login via either email or registration number
CREATE OR REPLACE FUNCTION get_user_for_login(p_identifier VARCHAR) 
RETURNS TABLE(user_id VARCHAR, reg_no VARCHAR, full_name VARCHAR, email VARCHAR, password_hash TEXT, department VARCHAR) AS $$
BEGIN
    RETURN QUERY 
    SELECT u.reg_no AS user_id, u.reg_no, u.full_name, u.email, u.password_hash, u.department
    FROM users u
    WHERE u.email = p_identifier OR u.reg_no = p_identifier;
END;
$$ LANGUAGE plpgsql;

-- 3. get_user_profile
-- Gets profile stats and whether the currently logged-in user (caller) follows them
CREATE OR REPLACE FUNCTION get_user_profile(p_target_id VARCHAR, p_caller_id VARCHAR)
RETURNS TABLE(
    user_id VARCHAR, reg_no VARCHAR, full_name VARCHAR, department VARCHAR, batch_year INT,
    follower_count BIGINT, following_count BIGINT, tweet_count BIGINT, is_following_by_caller BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        u.reg_no AS user_id, u.reg_no, u.full_name, u.department, u.batch_year,
        (SELECT COUNT(*) FROM follows WHERE following_reg_no = u.reg_no) AS follower_count,
        (SELECT COUNT(*) FROM follows WHERE follower_reg_no = u.reg_no) AS following_count,
        (SELECT COUNT(*) FROM tweets WHERE author_reg_no = u.reg_no AND is_deleted = FALSE) AS tweet_count,
        EXISTS(SELECT 1 FROM follows WHERE follower_reg_no = p_caller_id AND following_reg_no = u.reg_no) AS is_following_by_caller
    FROM users u
    WHERE u.reg_no = p_target_id;
END;
$$ LANGUAGE plpgsql;

-- ==========================================
-- TWEETS
-- ==========================================

-- 4. create_tweet
-- Inserts a new tweet and returns its generated ID
CREATE OR REPLACE FUNCTION create_tweet(p_user_id VARCHAR, p_content VARCHAR) 
RETURNS INT AS $$
DECLARE
    v_tweet_id INT;
BEGIN
    INSERT INTO tweets (author_reg_no, content)
    VALUES (p_user_id, p_content)
    RETURNING tweet_id INTO v_tweet_id;
    RETURN v_tweet_id;
END;
$$ LANGUAGE plpgsql;

-- 5. delete_tweet
-- Soft deletes a tweet, validating that the requester is the actual owner
CREATE OR REPLACE FUNCTION delete_tweet(p_tweet_id INT, p_user_id VARCHAR) 
RETURNS void AS $$
DECLARE
    v_owner VARCHAR;
BEGIN
    SELECT author_reg_no INTO v_owner FROM tweets WHERE tweet_id = p_tweet_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Tweet not found';
    END IF;
    
    IF v_owner != p_user_id THEN
        RAISE EXCEPTION 'Only the owner can delete this tweet';
    END IF;
    
    UPDATE tweets SET is_deleted = TRUE WHERE tweet_id = p_tweet_id;
END;
$$ LANGUAGE plpgsql;

-- 6. get_tweet_by_id
-- Fetches a single tweet's full details using the view
CREATE OR REPLACE FUNCTION get_tweet_by_id(p_tweet_id INT) 
RETURNS SETOF vw_tweet_details AS $$
BEGIN
    RETURN QUERY SELECT * FROM vw_tweet_details WHERE tweet_id = p_tweet_id;
END;
$$ LANGUAGE plpgsql;

-- ==========================================
-- FEEDS
-- ==========================================

-- 7. get_home_feed
-- Fetches timeline: tweets from people the user follows AND their own tweets
CREATE OR REPLACE FUNCTION get_home_feed(p_user_id VARCHAR, p_offset INT, p_fetch INT)
RETURNS SETOF vw_tweet_details AS $$
BEGIN
    RETURN QUERY
    SELECT * FROM vw_tweet_details
    WHERE user_id IN (SELECT following_reg_no FROM follows WHERE follower_reg_no = p_user_id)
       OR user_id = p_user_id
    ORDER BY created_at DESC
    OFFSET p_offset LIMIT p_fetch;
END;
$$ LANGUAGE plpgsql;

-- 8. get_trending_feed
-- Fetches the top liked tweets recently
CREATE OR REPLACE FUNCTION get_trending_feed(p_offset INT, p_fetch INT)
RETURNS SETOF vw_trending_tweets AS $$
BEGIN
    RETURN QUERY SELECT * FROM vw_trending_tweets OFFSET p_offset LIMIT p_fetch;
END;
$$ LANGUAGE plpgsql;

-- 9. get_user_tweets
-- Fetches the timeline for a specific user's profile
CREATE OR REPLACE FUNCTION get_user_tweets(p_user_id VARCHAR, p_offset INT, p_fetch INT)
RETURNS SETOF vw_tweet_details AS $$
BEGIN
    RETURN QUERY SELECT * FROM vw_tweet_details WHERE user_id = p_user_id
    ORDER BY created_at DESC OFFSET p_offset LIMIT p_fetch;
END;
$$ LANGUAGE plpgsql;

-- ==========================================
-- LIKES
-- ==========================================

-- 10. toggle_like
-- If liked -> unlikes. If not liked -> likes. Returns true if it is now liked.
-- Note: like_count update is handled automatically by the trigger we created earlier.
CREATE OR REPLACE FUNCTION toggle_like(p_tweet_id INT, p_user_id VARCHAR) 
RETURNS BOOLEAN AS $$
DECLARE
    v_liked BOOLEAN;
BEGIN
    IF EXISTS (SELECT 1 FROM likes WHERE tweet_id = p_tweet_id AND user_reg_no = p_user_id) THEN
        DELETE FROM likes WHERE tweet_id = p_tweet_id AND user_reg_no = p_user_id;
        v_liked := FALSE;
    ELSE
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (p_tweet_id, p_user_id);
        v_liked := TRUE;
    END IF;
    RETURN v_liked;
END;
$$ LANGUAGE plpgsql;

-- ==========================================
-- REPLIES
-- ==========================================

-- 11. add_reply
-- Inserts a reply. Note: reply_count is handled automatically by the trigger.
CREATE OR REPLACE FUNCTION add_reply(p_tweet_id INT, p_user_id VARCHAR, p_parent_reply_id INT, p_content VARCHAR)
RETURNS INT AS $$
DECLARE
    v_reply_id INT;
BEGIN
    INSERT INTO replies (tweet_id, author_reg_no, parent_reply_id, content)
    VALUES (p_tweet_id, p_user_id, p_parent_reply_id, p_content)
    RETURNING reply_id INTO v_reply_id;
    RETURN v_reply_id;
END;
$$ LANGUAGE plpgsql;

-- 12. get_replies
-- Uses a recursive CTE to build a threaded comment tree for a tweet
CREATE OR REPLACE FUNCTION get_replies(p_tweet_id INT)
RETURNS TABLE (
    reply_id INT, tweet_id INT, parent_reply_id INT, content TEXT, 
    created_at TIMESTAMPTZ, author_reg_no VARCHAR, author_name VARCHAR,
    depth INT, path INT[]
) AS $$
BEGIN
    RETURN QUERY
    WITH RECURSIVE reply_tree AS (
        -- Base case: Top level comments
        SELECT 
            r.reply_id, r.tweet_id, r.parent_reply_id, r.content, r.created_at, 
            r.author_reg_no, r.author_name,
            1 AS depth, 
            ARRAY[r.reply_id] AS path
        FROM vw_reply_details r
        WHERE r.tweet_id = p_tweet_id AND r.parent_reply_id IS NULL
        
        UNION ALL
        
        -- Recursive case: Replies to comments
        SELECT 
            r.reply_id, r.tweet_id, r.parent_reply_id, r.content, r.created_at, 
            r.author_reg_no, r.author_name,
            rt.depth + 1 AS depth, 
            rt.path || r.reply_id AS path
        FROM vw_reply_details r
        INNER JOIN reply_tree rt ON r.parent_reply_id = rt.reply_id
    )
    SELECT * FROM reply_tree ORDER BY path;
END;
$$ LANGUAGE plpgsql;

-- ==========================================
-- FOLLOWS
-- ==========================================

-- 13. toggle_follow
-- Toggles following status. Returns TRUE if now following.
CREATE OR REPLACE FUNCTION toggle_follow(p_source VARCHAR, p_target VARCHAR) 
RETURNS BOOLEAN AS $$
DECLARE
    v_following BOOLEAN;
BEGIN
    IF EXISTS (SELECT 1 FROM follows WHERE follower_reg_no = p_source AND following_reg_no = p_target) THEN
        DELETE FROM follows WHERE follower_reg_no = p_source AND following_reg_no = p_target;
        v_following := FALSE;
    ELSE
        INSERT INTO follows (follower_reg_no, following_reg_no) VALUES (p_source, p_target);
        v_following := TRUE;
    END IF;
    RETURN v_following;
END;
$$ LANGUAGE plpgsql;

-- 14. get_followers
CREATE OR REPLACE FUNCTION get_followers(p_user_id VARCHAR)
RETURNS TABLE(user_id VARCHAR, reg_no VARCHAR, full_name VARCHAR) AS $$
BEGIN
    RETURN QUERY
    SELECT u.reg_no AS user_id, u.reg_no, u.full_name
    FROM follows f
    JOIN users u ON f.follower_reg_no = u.reg_no
    WHERE f.following_reg_no = p_user_id;
END;
$$ LANGUAGE plpgsql;

-- 15. get_following
CREATE OR REPLACE FUNCTION get_following(p_user_id VARCHAR)
RETURNS TABLE(user_id VARCHAR, reg_no VARCHAR, full_name VARCHAR) AS $$
BEGIN
    RETURN QUERY
    SELECT u.reg_no AS user_id, u.reg_no, u.full_name
    FROM follows f
    JOIN users u ON f.following_reg_no = u.reg_no
    WHERE f.follower_reg_no = p_user_id;
END;
$$ LANGUAGE plpgsql;

-- ==========================================
-- DIRECT MESSAGES
-- ==========================================

-- 16. send_message
CREATE OR REPLACE FUNCTION send_message(p_sender VARCHAR, p_receiver VARCHAR, p_content TEXT)
RETURNS INT AS $$
DECLARE
    v_msg_id INT;
BEGIN
    INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content)
    VALUES (p_sender, p_receiver, p_content)
    RETURNING message_id INTO v_msg_id;
    RETURN v_msg_id;
END;
$$ LANGUAGE plpgsql;

-- 17. get_conversation
-- Gets paginated messages between two specific users
CREATE OR REPLACE FUNCTION get_conversation(p_a VARCHAR, p_b VARCHAR, p_offset INT, p_fetch INT)
RETURNS TABLE(message_id INT, sender_reg_no VARCHAR, receiver_reg_no VARCHAR, content TEXT, created_at TIMESTAMPTZ) AS $$
BEGIN
    RETURN QUERY
    SELECT dm.message_id, dm.sender_reg_no, dm.receiver_reg_no, dm.content, dm.created_at
    FROM direct_messages dm
    WHERE (dm.sender_reg_no = p_a AND dm.receiver_reg_no = p_b AND dm.is_deleted = FALSE)
       OR (dm.sender_reg_no = p_b AND dm.receiver_reg_no = p_a AND dm.is_deleted = FALSE)
    ORDER BY dm.created_at DESC
    OFFSET p_offset LIMIT p_fetch;
END;
$$ LANGUAGE plpgsql;

-- 18. get_inbox
CREATE OR REPLACE FUNCTION get_inbox(p_user_id VARCHAR)
RETURNS SETOF vw_inbox_summary AS $$
BEGIN
    RETURN QUERY SELECT * FROM vw_inbox_summary WHERE user_reg_no = p_user_id;
END;
$$ LANGUAGE plpgsql;

-- ==========================================
-- SEARCH
-- ==========================================

-- 19. search_users
-- Searches users by name, reg_no, or department (case insensitive)
CREATE OR REPLACE FUNCTION search_users(p_query VARCHAR)
RETURNS TABLE(user_id VARCHAR, reg_no VARCHAR, full_name VARCHAR, department VARCHAR) AS $$
BEGIN
    RETURN QUERY
    SELECT u.reg_no AS user_id, u.reg_no, u.full_name, u.department
    FROM users u
    WHERE u.full_name ILIKE '%' || p_query || '%' 
       OR u.reg_no ILIKE '%' || p_query || '%'
       OR u.department ILIKE '%' || p_query || '%';
END;
$$ LANGUAGE plpgsql;

-- 20. search_tweets
-- Full text search on tweets utilizing the GIN index we created
CREATE OR REPLACE FUNCTION search_tweets(p_query VARCHAR)
RETURNS SETOF vw_tweet_details AS $$
BEGIN
    RETURN QUERY
    SELECT * FROM vw_tweet_details
    WHERE to_tsvector('english', content) @@ plainto_tsquery('english', p_query);
END;
$$ LANGUAGE plpgsql;

-- ==========================================
-- ADMIN
-- ==========================================

-- 21. get_pending_reports
CREATE OR REPLACE FUNCTION get_pending_reports(p_offset INT, p_fetch INT)
RETURNS SETOF vw_pending_reports AS $$
BEGIN
    RETURN QUERY SELECT * FROM vw_pending_reports ORDER BY report_date ASC OFFSET p_offset LIMIT p_fetch;
END;
$$ LANGUAGE plpgsql;

-- 22. resolve_report_delete
-- Resolves a report by soft deleting the tweet it references
CREATE OR REPLACE FUNCTION resolve_report_delete(p_report_id INT, p_admin_id INT)
RETURNS void AS $$
DECLARE
    v_tweet_id INT;
BEGIN
    SELECT reported_tweet_id INTO v_tweet_id FROM reports WHERE report_id = p_report_id;
    
    IF v_tweet_id IS NOT NULL THEN
        UPDATE tweets SET is_deleted = TRUE WHERE tweet_id = v_tweet_id;
    END IF;
    
    UPDATE reports SET status = 'RESOLVED' WHERE report_id = p_report_id;
END;
$$ LANGUAGE plpgsql;

-- 23. resolve_report_dismiss
-- Dismisses a report without deleting anything
CREATE OR REPLACE FUNCTION resolve_report_dismiss(p_report_id INT, p_admin_id INT)
RETURNS void AS $$
BEGIN
    UPDATE reports SET status = 'DISMISSED' WHERE report_id = p_report_id;
END;
$$ LANGUAGE plpgsql;

-- 24. create_report
-- Dynamically handles reporting either a tweet or a user based on the target_type
CREATE OR REPLACE FUNCTION create_report(p_reporter_id VARCHAR, p_target_type VARCHAR, p_target_id VARCHAR, p_reason TEXT)
RETURNS void AS $$
BEGIN
    IF p_target_type = 'TWEET' THEN
        -- Cast the generic VARCHAR ID back to an INT for the tweet_id column
        INSERT INTO reports (reporter_reg_no, reported_tweet_id, reason)
        VALUES (p_reporter_id, p_target_id::INT, p_reason);
    ELSIF p_target_type = 'USER' THEN
        INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason)
        VALUES (p_reporter_id, p_target_id, p_reason);
    ELSE
        RAISE EXCEPTION 'Invalid target type. Use TWEET or USER.';
    END IF;
END;
$$ LANGUAGE plpgsql;
==========================================
1. USERS (30 realistic Pakistani students)
==========================================
INSERT INTO users (reg_no, full_name, email, password_hash, batch_year, department) VALUES
('24L-0941', 'Ahmad Sajid', 'ahmad.sajid@uni.edu.pk', 'hashed_password', 2024, 'CS'),
('24L-0102', 'Ali Khan', 'ali.khan@uni.edu.pk', 'hashed_password', 2024, 'SE'),
('24L-0103', 'Fatima Ahmed', 'fatima.ahmed@uni.edu.pk', 'hashed_password', 2024, 'AI'),
('24L-0104', 'Bilal Chaudhry', 'bilal.c@uni.edu.pk', 'hashed_password', 2024, 'DS'),
('24L-0105', 'Ayesha Syed', 'ayesha.syed@uni.edu.pk', 'hashed_password', 2024, 'CY'),
('24L-0106', 'Hamza Malik', 'hamza.malik@uni.edu.pk', 'hashed_password', 2024, 'CS'),
('24L-0107', 'Zainab Qureshi', 'zainab.q@uni.edu.pk', 'hashed_password', 2024, 'SE'),
('24L-0108', 'Umar Farooq', 'umar.farooq@uni.edu.pk', 'hashed_password', 2024, 'AI'),
('24L-0109', 'Sana Tariq', 'sana.tariq@uni.edu.pk', 'hashed_password', 2024, 'DS'),
('24L-0110', 'Usman Raza', 'usman.raza@uni.edu.pk', 'hashed_password', 2024, 'CY'),
('24L-0111', 'Iqra Hassan', 'iqra.hassan@uni.edu.pk', 'hashed_password', 2024, 'CS'),
('24L-0112', 'Hassan Ali', 'hassan.ali@uni.edu.pk', 'hashed_password', 2024, 'SE'),
('24L-0113', 'Nida Kamran', 'nida.k@uni.edu.pk', 'hashed_password', 2024, 'AI'),
('24L-0114', 'Abdullah Shah', 'abdullah.shah@uni.edu.pk', 'hashed_password', 2024, 'DS'),
('24L-0115', 'Maryam Baig', 'maryam.baig@uni.edu.pk', 'hashed_password', 2024, 'CY'),
('23L-0201', 'Saad Imran', 'saad.imran@uni.edu.pk', 'hashed_password', 2023, 'CS'),
('23L-0202', 'Hira Sheikh', 'hira.sheikh@uni.edu.pk', 'hashed_password', 2023, 'SE'),
('23L-0203', 'Taha Salman', 'taha.s@uni.edu.pk', 'hashed_password', 2023, 'AI'),
('23L-0204', 'Sadia Muneeb', 'sadia.m@uni.edu.pk', 'hashed_password', 2023, 'DS'),
('23L-0205', 'Muneeb Qasim', 'muneeb.q@uni.edu.pk', 'hashed_password', 2023, 'CY'),
('23L-0206', 'Rabia Siddiqui', 'rabia.s@uni.edu.pk', 'hashed_password', 2023, 'CS'),
('23L-0207', 'Farhan Jamil', 'farhan.j@uni.edu.pk', 'hashed_password', 2023, 'SE'),
('23L-0208', 'Khadija Rizvi', 'khadija.r@uni.edu.pk', 'hashed_password', 2023, 'AI'),
('23L-0209', 'Salman Zafar', 'salman.z@uni.edu.pk', 'hashed_password', 2023, 'DS'),
('23L-0210', 'Hussain Abbas', 'hussain.a@uni.edu.pk', 'hashed_password', 2023, 'CY'),
('23L-0211', 'Mahnoor Asif', 'mahnoor.a@uni.edu.pk', 'hashed_password', 2023, 'CS'),
('23L-0212', 'Shahzaib Akbar', 'shahzaib.a@uni.edu.pk', 'hashed_password', 2023, 'SE'),
('23L-0213', 'Bisma Nadeem', 'bisma.n@uni.edu.pk', 'hashed_password', 2023, 'AI'),
('23L-0214', 'Kamran Saeed', 'kamran.s@uni.edu.pk', 'hashed_password', 2023, 'DS'),
('23L-0215', 'Zara Khalid', 'zara.khalid@uni.edu.pk', 'hashed_password', 2023, 'CY');

-- ==========================================
-- 2. ADMINS (2 records)
-- ==========================================
INSERT INTO admins (username, email, password_hash) VALUES
('admin_root', 'admin@uni.edu.pk', 'hashed_password'),
('moderator_01', 'mod01@uni.edu.pk', 'hashed_password');

-- ==========================================
-- 3. TWEETS (15 realistic records)
-- ==========================================
INSERT INTO tweets (author_reg_no, content) VALUES
('24L-0941', 'Just finished setting up my Tkinter frontend. DB project is finally coming together!'),
('24L-0102', 'Is the cafe in the CS block open today? Need coffee ASAP for this assignment.'),
('24L-0103', 'Deep Learning is breaking my brain. Someone teach me backpropagation please 😭'),
('24L-0104', 'Data Science midterms are out. Pray for me y''all.'),
('24L-0105', 'Why does the university WiFi disconnect every 10 minutes? So frustrating!'),
('24L-0106', 'Anyone playing FIFA in the boys lounge after 2 PM?'),
('23L-0201', 'Seniors, any tips on getting a good FYP advisor?'),
('23L-0202', 'Software Engineering diagrams are going to be the end of me. UML is a nightmare.'),
('23L-0203', 'Machine learning class is actually super interesting this semester.'),
('23L-0204', 'Who parked their white Civic directly behind my car in the parking lot?! 😡'),
('24L-0111', 'Looking for group members for the Web Dev project. React/Node JS stack. HMU!'),
('23L-0212', 'Missed the 8:30 AM class because of traffic on Canal Road again.'),
('24L-0107', 'Can someone send the slides for Lecture 4 of Operating Systems?'),
('23L-0215', 'Cybersecurity CTF competition this weekend! Who''s participating?'),
('24L-0114', 'Just found out Python uses indentations instead of brackets... game changer.');

-- ==========================================
-- 4. FOLLOWS (20 relationships)
-- ==========================================
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES
('24L-0941', '24L-0102'), ('24L-0941', '24L-0103'), ('24L-0941', '23L-0201'),
('24L-0102', '24L-0941'), ('24L-0102', '24L-0106'), ('24L-0103', '24L-0941'),
('24L-0104', '23L-0204'), ('24L-0105', '24L-0111'), ('24L-0106', '24L-0102'),
('23L-0201', '24L-0941'), ('23L-0201', '23L-0202'), ('23L-0202', '23L-0201'),
('23L-0203', '24L-0103'), ('23L-0204', '24L-0104'), ('24L-0111', '24L-0105'),
('23L-0212', '24L-0112'), ('24L-0114', '24L-0115'), ('23L-0215', '24L-0105'),
('24L-0107', '23L-0202'), ('24L-0112', '23L-0212');

-- ==========================================
-- 5. LIKES (10 random likes on tweets)
-- ==========================================
-- Assuming tweet IDs are generated from 1 to 15 based on the inserts above
INSERT INTO likes (tweet_id, user_reg_no) VALUES
(1, '24L-0102'), (1, '24L-0103'), (2, '24L-0106'), 
(3, '23L-0203'), (5, '24L-0111'), (5, '23L-0212'), 
(7, '24L-0941'), (11, '24L-0105'), (12, '24L-0112'), 
(15, '23L-0201');

-- ==========================================
-- 6. DIRECT MESSAGES (5 realistic conversations)
-- ==========================================
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES
('24L-0102', '24L-0941', 'Hey Ahmad, how is the DB project going?'),
('24L-0941', '24L-0102', 'Almost done with the GUI. Will send you the code tonight!'),
('24L-0103', '23L-0203', 'Can you help me with the backpropagation assignment?'),
('23L-0203', '24L-0103', 'Sure, let''s meet in the library at 3 PM.'),
('24L-0104', '23L-0204', 'Did you find out who blocked your car?');

-- ==========================================
-- 7. REPORTS (3 pending reports)
-- ==========================================
INSERT INTO reports (reporter_reg_no, reported_tweet_id, reported_user_reg_no, reason, status) VALUES
('24L-0102', 10, NULL, 'Using aggressive language regarding the parking issue.', 'PENDING'),
('24L-0111', NULL, '23L-0212', 'Spamming the timeline with irrelevant posts.', 'PENDING'),
('23L-0201', 5, NULL, 'Spreading false rumors about the university WiFi.', 'PENDING');


==========================================
MEDIA STORAGE UPDATES
==========================================

ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar BYTEA DEFAULT NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar_filename VARCHAR(255);

ALTER TABLE tweets ADD COLUMN IF NOT EXISTS image BYTEA DEFAULT NULL;
ALTER TABLE tweets ADD COLUMN IF NOT EXISTS image_filename VARCHAR(255);

CREATE OR REPLACE FUNCTION upload_avatar(p_user_id VARCHAR, p_image_data BYTEA, p_filename VARCHAR)
RETURNS void AS $$
BEGIN
    UPDATE users SET avatar = p_image_data, avatar_filename = p_filename
    WHERE reg_no = p_user_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_avatar(p_user_id VARCHAR)
RETURNS TABLE(avatar BYTEA, avatar_filename VARCHAR) AS $$
BEGIN
    RETURN QUERY SELECT u.avatar, u.avatar_filename FROM users u WHERE u.reg_no = p_user_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION create_tweet_with_image(p_user_id VARCHAR, p_content VARCHAR, p_image_data BYTEA, p_image_filename VARCHAR)
RETURNS INT AS $$
DECLARE
    v_tweet_id INT;
BEGIN
    INSERT INTO tweets (author_reg_no, content, image, image_filename)
    VALUES (p_user_id, p_content, p_image_data, p_image_filename)
    RETURNING tweet_id INTO v_tweet_id;
    RETURN v_tweet_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_tweet_image(p_tweet_id INT)
RETURNS TABLE(image BYTEA, image_filename VARCHAR) AS $$
BEGIN
    RETURN QUERY SELECT t.image, t.image_filename FROM tweets t WHERE t.tweet_id = p_tweet_id;
END;
$$ LANGUAGE plpgsql;

INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2024338', 'Ahmad Sajid', 'ahmad_new@example.com', 2024, 'Computer Science', '$2b$12$W9GAZU4.1rRZWFvWX.FHlO5A.O2/fnQk1yXW2Qq1pV.nLWP/mAEFO') ON CONFLICT DO NOTHING;
UPDATE tweets SET author_reg_no = '2024338' WHERE author_reg_no = '24L-0941';
UPDATE replies SET author_reg_no = '2024338' WHERE author_reg_no = '24L-0941';
UPDATE likes SET user_reg_no = '2024338' WHERE user_reg_no = '24L-0941';
UPDATE follows SET follower_reg_no = '2024338' WHERE follower_reg_no = '24L-0941';
UPDATE follows SET following_reg_no = '2024338' WHERE following_reg_no = '24L-0941';
UPDATE direct_messages SET sender_reg_no = '2024338' WHERE sender_reg_no = '24L-0941';
UPDATE direct_messages SET receiver_reg_no = '2024338' WHERE receiver_reg_no = '24L-0941';
UPDATE reports SET reporter_reg_no = '2024338' WHERE reporter_reg_no = '24L-0941';
UPDATE reports SET reported_user_reg_no = '2024338' WHERE reported_user_reg_no = '24L-0941';
DELETE FROM users WHERE reg_no = '24L-0941';
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2024307', 'Mohsin Saeed', 'mohsin@example.com', 2024, 'Computer Science', '$2b$12$LoCcSycIVi3HzPe/w5.kseNEkQuvnM9oCLICNV7Mb3dI2eMye1K.q') ON CONFLICT DO NOTHING;

-- ==========================================
-- 2. GENERATE 1000 USERS
-- ==========================================
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022000', 'Test User 0', 'user_2022000@example.com', 2022, 'General', '$2b$12$dUig6VzSjZo/NDfB4UL8C.3419O6Yu0yd8algG3GQAcT/sucjp3Cm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022001', 'Test User 1', 'user_2022001@example.com', 2022, 'General', '$2b$12$S9XYeksdsBtKEUZKDl4nj.gPTHr9sXLEYcuCpIr1zxzN73mb8x/DW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022002', 'Test User 2', 'user_2022002@example.com', 2024, 'General', '$2b$12$e/E1M3B11QDRZ5tq05Wi8e3YFD/6v.4yQuMF4xWyn0/lYGhyXXaiC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022003', 'Test User 3', 'user_2022003@example.com', 2024, 'General', '$2b$12$XyXWVXCdJAcckz9qGrCYiO5mkvlq6U5uV8GjQfAKc65zPxJVQVIwm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022004', 'Test User 4', 'user_2022004@example.com', 2024, 'General', '$2b$12$2bxvBdy2dxNWXZX2993guO7F0MiQCvzHdeVxnbHm99tAJHLcEGL3G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022005', 'Test User 5', 'user_2022005@example.com', 2022, 'General', '$2b$12$WgdtVZsSQFo1ouMOE3rZfOBd5Q..rOeCaX1Ws28gQx9ACTeClgnZC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022006', 'Test User 6', 'user_2022006@example.com', 2023, 'General', '$2b$12$BQQVbnf5ApkT/ig/2KL03eB5rsgV9vCLHPMTRymCU8Ksm3LyWIYEu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022007', 'Test User 7', 'user_2022007@example.com', 2025, 'General', '$2b$12$iDgWrYbtn3d2ER0y7N3ebORJI7q/i3YFDY6TA2bWecPVW.fYJtQcy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022008', 'Test User 8', 'user_2022008@example.com', 2022, 'General', '$2b$12$2P0thlRQPDbVpwYAgyUcI.jIWmLyFdTla2XzkPz/0U5SLfEviBFv6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022009', 'Test User 9', 'user_2022009@example.com', 2023, 'General', '$2b$12$iaEg/TXugFL3X1G6mj9JIe8wN65PGR.EjX7Y8Fe3ojl6s7Vcc9WAS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022010', 'Test User 10', 'user_2022010@example.com', 2024, 'General', '$2b$12$ioTT2kN.NKYQnsJ6gPYJEuAHzQAH3L6GYE2ixGcP/.UIvHTo3TdM6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022011', 'Test User 11', 'user_2022011@example.com', 2025, 'General', '$2b$12$nMN3y5VuvPspP5wCsTiD5eDzdjA3n01Xw1/rwUBg7QP6q38FrEcmy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022012', 'Test User 12', 'user_2022012@example.com', 2025, 'General', '$2b$12$FH5Bb9hwK4bx6Ao/Zxt6sucMmlCkrvBH014to..Dx25yLMyERY.Fe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022013', 'Test User 13', 'user_2022013@example.com', 2022, 'General', '$2b$12$GOLG7Eg20GBskiRMDA5lMeaT3XpccAJuOZ.rg4ceruY0gsYmJJAaK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022014', 'Test User 14', 'user_2022014@example.com', 2024, 'General', '$2b$12$541GPQaqysUfdu5qkh4F2OTyrna0tA2goBx2nIGIf.R9gNh7rCQZS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022015', 'Test User 15', 'user_2022015@example.com', 2024, 'General', '$2b$12$CBzPohLqiC0YHLxMDpH90eMdW9qoVTWfCHo.yXiZqQVbQKpi6uIeC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022016', 'Test User 16', 'user_2022016@example.com', 2024, 'General', '$2b$12$0kZRy8aamG93HuwbY85DuOCYvuqN5EDlZL1hc/VXKMYQIGcpAoJUe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022017', 'Test User 17', 'user_2022017@example.com', 2022, 'General', '$2b$12$LY8pTaMEfron2FOhForxfeIeiWnGUjAlzfWd52HF5hd/9jgsftotu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022018', 'Test User 18', 'user_2022018@example.com', 2023, 'General', '$2b$12$Z7sSFXjgT8mU6UxxajG6QOBuyizj4Etx76v8b02xaLoKgA7EFl2Y2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022019', 'Test User 19', 'user_2022019@example.com', 2025, 'General', '$2b$12$VGp2pDMpXdAZUvp.AnUmUu7UWMAkOgYEtjTmO551uKm3GgiROvIri') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022020', 'Test User 20', 'user_2022020@example.com', 2025, 'General', '$2b$12$34RnYmSf1zYHLiveOVicp.kSnBYZwWGmdLucF6IlCyyQYP7muZJei') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022021', 'Test User 21', 'user_2022021@example.com', 2024, 'General', '$2b$12$7lcGNsk2fnRFBO13GnGgBeQv8NXReqyknrMO6TzJIjB/Z3fAcMldC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022022', 'Test User 22', 'user_2022022@example.com', 2024, 'General', '$2b$12$MRovOyH8lxOjrArF13c01OMQi16mGWmjSKvNfzQgMD92SV6usiU8G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022023', 'Test User 23', 'user_2022023@example.com', 2023, 'General', '$2b$12$.oTLNJicLEGsvK8GsICzNewrtYgTRhWhz0fPojUi/cXOMI6P4Twa6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022024', 'Test User 24', 'user_2022024@example.com', 2025, 'General', '$2b$12$lMBqY89D2GJyFrbKSn5HfOLn4FqjH2JxEY33vOtpy9XmybyxajONm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022025', 'Test User 25', 'user_2022025@example.com', 2023, 'General', '$2b$12$oemiZcPptvtQOEOD7m024eNimiIErM5yDtitvU7YbNSmfp4bxV1je') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022026', 'Test User 26', 'user_2022026@example.com', 2025, 'General', '$2b$12$0J3.0xq4NDLHWioPIYJgV.aqNkuo/8vENKvLwJ4el5FKPP3kMC.V6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022027', 'Test User 27', 'user_2022027@example.com', 2025, 'General', '$2b$12$iEIlRdJ3Jr3AyyMe6zi5o.Ws5B9cXij0pHSiSiR5UMZoIL.ILkdY.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022028', 'Test User 28', 'user_2022028@example.com', 2025, 'General', '$2b$12$gKuiLTw6G2WsWWp7c9PkOe9JgP1WNsBMO8C633KHZwwnv0Ao9YWCi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022029', 'Test User 29', 'user_2022029@example.com', 2023, 'General', '$2b$12$qUCcMBid6swQcuNXZraPkO7rd9T87VAiB33QfhQjE6gJkGQvGIkUu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022030', 'Test User 30', 'user_2022030@example.com', 2023, 'General', '$2b$12$V/dTrX4TfTcDrqCaP36TW.uhBSJdudSsavzqvO6WWIsVmf6uXZf5W') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022031', 'Test User 31', 'user_2022031@example.com', 2025, 'General', '$2b$12$qj6VSLWBXUab8DugLPlEl.LwBYKI33qZH5VIlKfWa00fn7J5mTUTW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022032', 'Test User 32', 'user_2022032@example.com', 2024, 'General', '$2b$12$nyiCpLwLNzqkGIXmVdl/5e3eVDTIH41TbU8tmLgB5.MtTWGqJqvM6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022033', 'Test User 33', 'user_2022033@example.com', 2024, 'General', '$2b$12$4WMDy.GuTx8LbiOPsXaRXOAXEjYpQ.0Yjc.QyLmHSm7z0n6t.0J2S') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022034', 'Test User 34', 'user_2022034@example.com', 2022, 'General', '$2b$12$cyBTuHF5C2c5LiYiLGh39ugGNOGRz8pj/v5z7vVAW5rL5QpcvA7pm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022035', 'Test User 35', 'user_2022035@example.com', 2025, 'General', '$2b$12$XhJU83sAdKlHC4stVPJKMevzn4BsZaTOaY5JxPo.bdbqNIoDhby/2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022036', 'Test User 36', 'user_2022036@example.com', 2022, 'General', '$2b$12$ITFDe7QX9vIwYsTsv6VXu.5gIL/xM.zd5CmaUBVZHr/C8sbhXL5Vq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022037', 'Test User 37', 'user_2022037@example.com', 2023, 'General', '$2b$12$/kOGt6D/WDfWEGWNSkBPLO4itA8b0dAAf.PH9FRFLmenVpEuDNwrS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022038', 'Test User 38', 'user_2022038@example.com', 2022, 'General', '$2b$12$9agti2LFsT4VCrPrx8T.UeuBE3.FhuKq17WLdrQ1lkxTR81GW.W9q') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022039', 'Test User 39', 'user_2022039@example.com', 2024, 'General', '$2b$12$pUOTFPljZsOjpzDHmUxB/OWJyNTqIFHGo6xT0UBtmEOXjgG9qJvQ6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022040', 'Test User 40', 'user_2022040@example.com', 2022, 'General', '$2b$12$EwrzWzwDtwHqUZ3N7qxXzeGaUYcL7u4HO7M.gd8phT2X2VhLAWzry') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022041', 'Test User 41', 'user_2022041@example.com', 2024, 'General', '$2b$12$uNu6hXq3aAg65pPhVl6nueyhA81qzfR9rLzkxndF2QZrFFv6pUAb6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022042', 'Test User 42', 'user_2022042@example.com', 2022, 'General', '$2b$12$hfBfqkvADEqd6XMnOsyGWOnffK1LLYLazeHj8VXdr8yAxeNGGwWeW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022043', 'Test User 43', 'user_2022043@example.com', 2023, 'General', '$2b$12$.zcVPEypiMbw4l1PZ8ORduSl8.w9TfVPpeTQaeic/VZisj63K0y6W') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022044', 'Test User 44', 'user_2022044@example.com', 2024, 'General', '$2b$12$zfKqu4Df5ZaqGJdZAIaCnuykKqdNHrVM1i1EoZy4rkVx0QCte49n2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022045', 'Test User 45', 'user_2022045@example.com', 2022, 'General', '$2b$12$LYmCSa2fMKGuQtomTbIo6.g9pozEhUGXxTAzhUfdwWZT6vKVj/0I.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022046', 'Test User 46', 'user_2022046@example.com', 2023, 'General', '$2b$12$uK0moGyd.0F2qubsBe.QR.Pm/ha2JHriN3Ag5RUmc5lknkLwbrUim') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022047', 'Test User 47', 'user_2022047@example.com', 2023, 'General', '$2b$12$Hf6unAtoc2gOzQtLzVvcSeSyejX0fi4qrdwDXLeRS/Ndv9iV4qg/C') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022048', 'Test User 48', 'user_2022048@example.com', 2022, 'General', '$2b$12$9JwUjOwIVrwR4Ivv2.GE4uUAUAfNjmTO.XLZEik3eElh0cDnsS5Fu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022049', 'Test User 49', 'user_2022049@example.com', 2022, 'General', '$2b$12$dY6JVw88KKr/NI0B3yFgQO4w8cXfKYFRTvT/Jz5FiaPxJKbV9OzZO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022050', 'Test User 50', 'user_2022050@example.com', 2022, 'General', '$2b$12$cKBrMLCyCCw5wmg8XKsw1eL0rdDhRZ11IXDXHFRRttOiMkFhUFKTW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022051', 'Test User 51', 'user_2022051@example.com', 2023, 'General', '$2b$12$wh6aioTIu4gRGgVg0L.mzeX5u.Uy0855KXYjM/WOgc.x/tf3LITpm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022052', 'Test User 52', 'user_2022052@example.com', 2024, 'General', '$2b$12$D3qnL7qk3DzQ/efXKAJALejXs5jvYPeI1C4gp83FwbkwdNjSkHH/e') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022053', 'Test User 53', 'user_2022053@example.com', 2025, 'General', '$2b$12$gl5m0cMzldmVrpSv7HYmL.BKHxD2LcLgHLEizdyeLrPtigF3JQCZm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022054', 'Test User 54', 'user_2022054@example.com', 2023, 'General', '$2b$12$s2A7/bEVBgDjpJ3lmIjMku5qGNCXgySARdQ.vkLopOxwPFDfWhskm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022055', 'Test User 55', 'user_2022055@example.com', 2022, 'General', '$2b$12$9j/JCAnO1uZXizAQhk/88O05Kpq1hCsaEfjuitffkyNV5OO2s2jYC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022056', 'Test User 56', 'user_2022056@example.com', 2025, 'General', '$2b$12$svRMahcCZEMGg0e1nMfPB.j6hm/myUi8fLJEXjaG986Ah5q4GJyRG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022057', 'Test User 57', 'user_2022057@example.com', 2022, 'General', '$2b$12$n2EW/IX7eHjvUDZxfiPYIeB8HGYKJqodHDSZoVP4ejD9TRjVVtH4G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022058', 'Test User 58', 'user_2022058@example.com', 2023, 'General', '$2b$12$xRB6O6dmMEHMo5wxmiP6t.ZrvMWZs.ULwCJe6QuYBcxmlHHWgKaf.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022059', 'Test User 59', 'user_2022059@example.com', 2025, 'General', '$2b$12$iznakwZKN.R/5mhNt0QZ.e/w7aYdhMhUAWICViLAH6wlpdtR3CzHa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022060', 'Test User 60', 'user_2022060@example.com', 2024, 'General', '$2b$12$j5yvngUQLR9VAku.hsxWd.Soajm8ZrPIF1.LrKdHEtasmpdC284yK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022061', 'Test User 61', 'user_2022061@example.com', 2025, 'General', '$2b$12$Sm5SqbifR1rNyZ05SER6ReDROSXOXCDU.nZmaGbubqmv4KhPKodj.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022062', 'Test User 62', 'user_2022062@example.com', 2022, 'General', '$2b$12$sipzOVTWhAc1Z6YtVNLjX.mMASyNP2pa4MbnvUNhgKwinqixJefPi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022063', 'Test User 63', 'user_2022063@example.com', 2024, 'General', '$2b$12$DsiRJbEzbcNb4bStchmlVex64tvQDRuMXMS3./ZXzTWtvQh9m/STi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022064', 'Test User 64', 'user_2022064@example.com', 2024, 'General', '$2b$12$uWf/x8aKQ9ZfxkDECs97zu16CzEZ98zgUdMRvmYmKuFxsKknYTUnm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022065', 'Test User 65', 'user_2022065@example.com', 2022, 'General', '$2b$12$lCrlFTJQDcKP2WRtyF46eu8iPyAi5KGcsIr/fVQI7HxGvk1qlO/D.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022066', 'Test User 66', 'user_2022066@example.com', 2024, 'General', '$2b$12$BId3LHSP/IdyUIXQrt5IWOp3y.GgUDrCftT.9kFuWTF15t64S2Cqa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022067', 'Test User 67', 'user_2022067@example.com', 2022, 'General', '$2b$12$J7RGkMQs1CtunIdsO7G1C.SDfVcQbaDpxl9c45RFtwK6X5J7QoDpu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022068', 'Test User 68', 'user_2022068@example.com', 2024, 'General', '$2b$12$JM2.oLp0twFKf1jcUaUYIO88fucU7NRqetg/UHPRq50L7gcpmhDBm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022069', 'Test User 69', 'user_2022069@example.com', 2022, 'General', '$2b$12$wdC8WZjK/nj1rd.IXnnOzOmPei541/R8DtUndTgO.CzadpDw76i4u') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022070', 'Test User 70', 'user_2022070@example.com', 2023, 'General', '$2b$12$r9di8WyCV80DeOFqu.yMMODsedO8rpaKafE4ipeHOB5P0D0aXINv.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022071', 'Test User 71', 'user_2022071@example.com', 2025, 'General', '$2b$12$HPJLU.T.kz2FwKqpigvg8eN5l3LGOlVmozPfRpA49sR6W6UnE0Tfy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022072', 'Test User 72', 'user_2022072@example.com', 2023, 'General', '$2b$12$j941ukbfohveZ7Bux6aBCuIK9WtEL2k1mauznq7BsOYSBh4NW2RsO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022073', 'Test User 73', 'user_2022073@example.com', 2024, 'General', '$2b$12$hax5O7GAb.YNP/L7aybv9eeWG0UglvOAUNAhH3z2hAGtFlbt3FHuW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022074', 'Test User 74', 'user_2022074@example.com', 2023, 'General', '$2b$12$NwRs47S2.qXte2Q2hq4t1u6TJsmfUIxFcrqMeu7eTkSyQMR9rhZ26') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022075', 'Test User 75', 'user_2022075@example.com', 2023, 'General', '$2b$12$8rkBkKRPnI5.jbczurTuyOIVZX4IkOSrT2vrr4JYaG7nlKBsXZKIy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022076', 'Test User 76', 'user_2022076@example.com', 2023, 'General', '$2b$12$5aeRjE400shNA7Z2fOqsTejt8bcTthqIDLPx6mVaEwpnou6bFxkk.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022077', 'Test User 77', 'user_2022077@example.com', 2025, 'General', '$2b$12$z6X.vLoLKVLNrzuJ0dMdu.sYes2QSsydLMySTsWXGmFpmNyuIKNaC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022078', 'Test User 78', 'user_2022078@example.com', 2024, 'General', '$2b$12$cUYJPu4pS2WKQ0DUDxO0kOpiAjx4iJqC6FcLzPYGNtS3HpO.VBALG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022079', 'Test User 79', 'user_2022079@example.com', 2022, 'General', '$2b$12$qZdpL5Zq8EPY2Ad4vseBJeaivJwsWDxcdF/nJKzSL.jyi.YFc7PCu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022080', 'Test User 80', 'user_2022080@example.com', 2023, 'General', '$2b$12$haJEpJmXyIOSmmj1zwYLw.niHvPM8394SVeStEzXPQNznWY.8isyG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022081', 'Test User 81', 'user_2022081@example.com', 2022, 'General', '$2b$12$t2gSJAmHw9f3Y/nZ4ayPhehDc5XoIxfeg.Bmtlxytke/vqrxYvfZK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022082', 'Test User 82', 'user_2022082@example.com', 2024, 'General', '$2b$12$L/0S.bl1/6UepZdMha0ih.l/ifWxXeykeMAbChJL3PaPVVm0UV.V6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022083', 'Test User 83', 'user_2022083@example.com', 2023, 'General', '$2b$12$M/SXlmBY.VsctztuSu7ZXOdHqv/rlDLZVxXYwS38dhMVev.yucblG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022084', 'Test User 84', 'user_2022084@example.com', 2022, 'General', '$2b$12$btSpkf7ioZKPBKYy65sG6ev3Jgbg6ZQaKuukIGtsasUQ5JqpEXeQ6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022085', 'Test User 85', 'user_2022085@example.com', 2025, 'General', '$2b$12$NW955waeZbqo7udnFpg3ZuWOVdvsTgtWpEnOaaTDA/LNoh3Pq0FKK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022086', 'Test User 86', 'user_2022086@example.com', 2022, 'General', '$2b$12$oOohCmLk6PwZ.EJ5dDXILekqPISWTOujLQ3gJpoD7rhjE6zDUAjbG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022087', 'Test User 87', 'user_2022087@example.com', 2023, 'General', '$2b$12$zar15nxgh7pCjH7oYKeFnuA8KLekBL4JzH0P1vgjL2CtgGktZKFjO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022088', 'Test User 88', 'user_2022088@example.com', 2025, 'General', '$2b$12$wvAdaBduVw0xxNtsoQxSgeogFixxGJzWHOqtFEtg7HC62YaGfRa.e') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022089', 'Test User 89', 'user_2022089@example.com', 2022, 'General', '$2b$12$POQTUDUOicJMYIckFNEQMe8gdUa.ktx5YIoEtwRUqC4DL6tR91WRS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022090', 'Test User 90', 'user_2022090@example.com', 2023, 'General', '$2b$12$cQyLheveyZQVn9.9.gd5LOmR5elntlpWIv1b6ebWwVvTQAq/1Wca6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022091', 'Test User 91', 'user_2022091@example.com', 2024, 'General', '$2b$12$Sosx1ck2xHpKc7wUXufBOOiwI8C9k0teH0KgoohYCQ83W/ZPd09da') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022092', 'Test User 92', 'user_2022092@example.com', 2025, 'General', '$2b$12$e5GFCuKO2EeEoEf/vRFlneY1EcEX6NXyos4q8FAdAHWA83njfVd6i') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022093', 'Test User 93', 'user_2022093@example.com', 2025, 'General', '$2b$12$kgiR6jR5LwsEjBhoiyt0Xe4fLZedZAlRrqIwis.LiP85D9x/Wj.Zq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022094', 'Test User 94', 'user_2022094@example.com', 2023, 'General', '$2b$12$90QvX4LMkH2pElZ6ZWubguMIZxG1cJOESgTMuCWwSnvUaOK4576iq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022095', 'Test User 95', 'user_2022095@example.com', 2022, 'General', '$2b$12$lfR5vycpZLfPMRzrtigDOegzqp5e/k5bDEOAwcg2WGO.eQ2XB6ta.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022096', 'Test User 96', 'user_2022096@example.com', 2025, 'General', '$2b$12$.jz1hXer.nxwB0lFL5jYq.uIV5D7fVe84vsAcI9BETUdtHcdULYqK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022097', 'Test User 97', 'user_2022097@example.com', 2025, 'General', '$2b$12$7YenOm.m5VWzOyAE2TVAweKwBVsvvAPg8NnA1MCPddeccLPMPdN7S') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022098', 'Test User 98', 'user_2022098@example.com', 2023, 'General', '$2b$12$JSbJyVsM/rg4SiI559zOvOWdpQag309BlawPdTf7DfenEz6zHjbAK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022099', 'Test User 99', 'user_2022099@example.com', 2025, 'General', '$2b$12$jMjluMM86MBYJkPy7OEWku0irvKwzutGa9394GoUjVYl458sTM3aG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022100', 'Test User 100', 'user_2022100@example.com', 2024, 'General', '$2b$12$siD8YB//TtpV823LobxB.uxJVFWOg5AWtxvK/bDVjpYzMN5TAtD/G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022101', 'Test User 101', 'user_2022101@example.com', 2023, 'General', '$2b$12$8sZR/wAQdjWiledWsstWLOR/O2X34gk2HGZahtwL6azlmcrEGd4xi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022102', 'Test User 102', 'user_2022102@example.com', 2024, 'General', '$2b$12$8UQhERFM44SG8/xqnJrHpOJny.aNy7vFC0gg/z/3NxxH1B2kobdIK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022103', 'Test User 103', 'user_2022103@example.com', 2024, 'General', '$2b$12$RsdIm5lTjwhXa0cBPw0ig.IlOVcME/KsZX/1TXBPC9rrt1XKb54tq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022104', 'Test User 104', 'user_2022104@example.com', 2025, 'General', '$2b$12$AJMU0M03v7l10/AWXK9j8.6dvpy3PI/8Vm4gqnmYDoG1Eo0ygOhwS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022105', 'Test User 105', 'user_2022105@example.com', 2024, 'General', '$2b$12$8SfOiwlrWfFTE51kqKoBW.dBNwxFNs.TSOXPZ6FMtYbUTLEDIF2Uq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022106', 'Test User 106', 'user_2022106@example.com', 2022, 'General', '$2b$12$n8P5vfYEjQcx2BdmVdpUSOLNU//yiSIyDciBr/tJVYvfKS3p8LIXy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022107', 'Test User 107', 'user_2022107@example.com', 2025, 'General', '$2b$12$NfvaPFeFMmRTKvW9VnQYr..Hy8Kj.zSi1o.ZR7ne.ILZ4Es8xsu6y') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022108', 'Test User 108', 'user_2022108@example.com', 2025, 'General', '$2b$12$4x/ioLMRaf1Jl83I3sWc2OVT/llfZmy1O7YLpaOKexlUE3BaeMJUO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022109', 'Test User 109', 'user_2022109@example.com', 2025, 'General', '$2b$12$uXZJldKM7JXo8zYktGqbie6d7akWyxnejUqq.QWLh7ej4ipoNKaW6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022110', 'Test User 110', 'user_2022110@example.com', 2023, 'General', '$2b$12$MikAoO3XryMxxBjk9knTd.6jegffaRBhZVzEg8JgortyvgWz.owJe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022111', 'Test User 111', 'user_2022111@example.com', 2025, 'General', '$2b$12$pRvrs031n/kHaP9mWsfktegAxPF4dKnApxXVx2QlrRjPLsy8hsTUW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022112', 'Test User 112', 'user_2022112@example.com', 2024, 'General', '$2b$12$GzmoZsiP3QfZbD2XKCqEmOLF2VVXSWhVKsThjSrcSDQ12/Cx6uM82') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022113', 'Test User 113', 'user_2022113@example.com', 2024, 'General', '$2b$12$fMvlFQ7HbKsDc1xfSOGL6OtI5OpEdRO5H35sa3wT1x3eSVS.MpTie') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022114', 'Test User 114', 'user_2022114@example.com', 2022, 'General', '$2b$12$OTSQQtHlirZdFDXzkhOmXud8XGS3ArKfTZoevPBBheijXrfIjFfme') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022115', 'Test User 115', 'user_2022115@example.com', 2022, 'General', '$2b$12$4pQYplz05qyoRohJQ7dxKuQg3fVNkn01rgb7GAgTsnLgwbDmGMsgy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022116', 'Test User 116', 'user_2022116@example.com', 2025, 'General', '$2b$12$HZ1wczRNjROTNtANcuEA5O2E/MkJylAGKLmbvKi79ysmJE6x0/iJy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022117', 'Test User 117', 'user_2022117@example.com', 2025, 'General', '$2b$12$Bq1e2iTexKusrhpRrMVFtOP/APV6c.tk6aRrkqlLJaDk1PQZPQEQW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022118', 'Test User 118', 'user_2022118@example.com', 2022, 'General', '$2b$12$fJMqwDLcyEt2BCX4lkcoleLbWtIkey09acVF5oO0Ot6vXzHDMoVQq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022119', 'Test User 119', 'user_2022119@example.com', 2024, 'General', '$2b$12$GE1boj1c8WrlpMAwxlm7yu3t3O.XanTrlH16kO3jr54.kAkc9C.Gq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022120', 'Test User 120', 'user_2022120@example.com', 2022, 'General', '$2b$12$zEYbNzegGOO4GJd6rbcVb.1A3nVfSO/NT3M.fzmlxGku.LFcFFUOG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022121', 'Test User 121', 'user_2022121@example.com', 2023, 'General', '$2b$12$IovjHKibi62bUqdW0v0XZeoeBygFhUS1APNG.Ozz6P8fOOlWrnpRm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022122', 'Test User 122', 'user_2022122@example.com', 2022, 'General', '$2b$12$lkycAHKuIQLnoAW4wsmRW.kd2ICQtAEaHcaCZJwRaiFonf2QHLZnu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022123', 'Test User 123', 'user_2022123@example.com', 2025, 'General', '$2b$12$aIn7pq.Jy9Q1V1dPVTJs5utUWBfllxl0sjLJ1w4vRd7ZP9dw3zVda') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022124', 'Test User 124', 'user_2022124@example.com', 2025, 'General', '$2b$12$mOm5669uEGIaBXnPiW8tWebI4T3DWR2/uWBBae59WRA.GQQewIirq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022125', 'Test User 125', 'user_2022125@example.com', 2025, 'General', '$2b$12$Fa0oUF41vNwGVHptNmYqCepxvAg4Do4c24./72SZLh2sAb2jxqbMK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022126', 'Test User 126', 'user_2022126@example.com', 2023, 'General', '$2b$12$pXIIHgYAafV3xvSgmHV0ReVy6HGPWD4/QzID4ZYuVaeC6POezph92') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022127', 'Test User 127', 'user_2022127@example.com', 2024, 'General', '$2b$12$AcUuMN94sKR3tZEd9s6Ke.iyrAVHNRgdJ0uTarkl6gis6DxtP.TEC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022128', 'Test User 128', 'user_2022128@example.com', 2023, 'General', '$2b$12$BHKOPh.SLKw/8L74f8OCke6KFHjX3Q1MZEUPh5QkJqEt0/x5ix0WG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022129', 'Test User 129', 'user_2022129@example.com', 2024, 'General', '$2b$12$o1ImJWUKDCXSKtmUKj5CTeLI0Sc591AK7ySn0rEf7C4hW1rhbw5Sa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022130', 'Test User 130', 'user_2022130@example.com', 2024, 'General', '$2b$12$79ZhyDGOelAfIHgE7hqlfeoaw1cJ3EvRRm7lJQ7kFILRrtYYsVEU.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022131', 'Test User 131', 'user_2022131@example.com', 2025, 'General', '$2b$12$aPbjijgPSYxqK22e2e1SkeHUaix97B9x4zX3IuMu3c9i7pI6xlmEK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022132', 'Test User 132', 'user_2022132@example.com', 2024, 'General', '$2b$12$nqTPiLiwAjnTeangPRjesODaTTbIp7nKBqydriioQi.09nIOwOZG.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022133', 'Test User 133', 'user_2022133@example.com', 2023, 'General', '$2b$12$1PCQoJYieZ7qi8NAVo9Zhu.EizU.TbwGknj0JDCCVOfarZMlIZOKe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022134', 'Test User 134', 'user_2022134@example.com', 2022, 'General', '$2b$12$oEL08ZxJviwMy95SMRbcS.g0VtSCfntAHW24PUJrcMLob3DIv1MPu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022135', 'Test User 135', 'user_2022135@example.com', 2025, 'General', '$2b$12$II1FROp2SXKqG1hlARY99OS/WuXZf/DDum.uWh76A06HBMYXhKyZK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022136', 'Test User 136', 'user_2022136@example.com', 2024, 'General', '$2b$12$bF4nnEi/olEK6JIyVCeXeOQFSOgoQH0frbIDD./gEJtXDsjearbpe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022137', 'Test User 137', 'user_2022137@example.com', 2025, 'General', '$2b$12$IS9l3lfE8pMz/jZUGUaEMe73NIy.NGBNAffplA6EV8GDDnOZEXFWO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022138', 'Test User 138', 'user_2022138@example.com', 2024, 'General', '$2b$12$LM09rUwFEmG/JbDMB/kjeeLRsGk5km9lwN9LqfaBT4mNgTvQ/0ZOC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022139', 'Test User 139', 'user_2022139@example.com', 2023, 'General', '$2b$12$yAxD256TXjvI6dgP7Yh0M.R5X6BRTMnEinHNU6FNXeSsGsbN7AsHe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022140', 'Test User 140', 'user_2022140@example.com', 2025, 'General', '$2b$12$U9bxa/1X7BWB34gvKutm7eakrqndYHrY8ogPm0BL3Ti.556vF3nAa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022141', 'Test User 141', 'user_2022141@example.com', 2025, 'General', '$2b$12$ekDzeDcu8d38.sL5QyXduunX9UC6AYoicf4fQ/fe2OYWo4UVUe1Iu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022142', 'Test User 142', 'user_2022142@example.com', 2023, 'General', '$2b$12$QkBum.mp0T9uu.WhVvDF.exKj0i9AQZ1jnsw3nOqOsum.WfOwaO1O') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022143', 'Test User 143', 'user_2022143@example.com', 2023, 'General', '$2b$12$4YrVoIyyBOIxf5yui8kmr.LKZe1qZ6T5tnw5HaenDxYX2fQkzgyrm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022144', 'Test User 144', 'user_2022144@example.com', 2022, 'General', '$2b$12$TDWS6A.M3BTJdces9Zf9l.C1jvoKyblp0Kng6f1nRh7nyz6guN7K6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022145', 'Test User 145', 'user_2022145@example.com', 2022, 'General', '$2b$12$XKeJ7qj6IoYy4acD/6iD9.eM4hcFRCLNQNJSvSb5uvJBNqH/b9DDm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022146', 'Test User 146', 'user_2022146@example.com', 2022, 'General', '$2b$12$lUhyTTgXhhpZUKN8stidu.fQE3o30gH3kVtjF8DGMpz/6nOMYJ6Xe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022147', 'Test User 147', 'user_2022147@example.com', 2025, 'General', '$2b$12$qjKezzfl3UqOSGPGx6YXj.12cZ5k/xo0QyB0e/rBMQWcKayMA0dai') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022148', 'Test User 148', 'user_2022148@example.com', 2022, 'General', '$2b$12$J6UCU4J/zaZcZ3taQ44t9.MJKuwkAdpEoLGNyM9JesybRz2S24IoW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022149', 'Test User 149', 'user_2022149@example.com', 2023, 'General', '$2b$12$mW3k27Xdq9fk7pa.qSDd7.zTzrDLhTLrlnWE561.mAWv3i9Cawryi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022150', 'Test User 150', 'user_2022150@example.com', 2025, 'General', '$2b$12$qbwLf5ve04qsyO7w3ZkNiOfZsBPN8yctqcFVndnaYqRjxhxvEK4la') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022151', 'Test User 151', 'user_2022151@example.com', 2023, 'General', '$2b$12$NWpgEa90MzJF2Ip2uPArcOMuuQN21s9KGsl7DxwtC.Ee5cROFqYiC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022152', 'Test User 152', 'user_2022152@example.com', 2023, 'General', '$2b$12$Uhr1yEXBL5EbxzG70DHuUe5ZOdFmNzvpEj4pqkOq3rp2j68V/KN7i') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022153', 'Test User 153', 'user_2022153@example.com', 2024, 'General', '$2b$12$px3kZS2oyFxhUGTGsSBmm.IHVLi1ncBsTsjiCo0LAas.yMY2.XISK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022154', 'Test User 154', 'user_2022154@example.com', 2022, 'General', '$2b$12$VXVahX8Ihuhv58InxM5FBuYMF2cXbo6GOTP0xYkCflLYWJROQBSY6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022155', 'Test User 155', 'user_2022155@example.com', 2025, 'General', '$2b$12$6f/kpPEO9JlGK4yx0Ikp0.rmcZux1UbDedMBF0UqjV1BOqspK353G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022156', 'Test User 156', 'user_2022156@example.com', 2024, 'General', '$2b$12$aP9UJABWcoF0oBJrJC3OouZvSlCWAYLpB9.DsEDOV/q8fetaunb7W') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022157', 'Test User 157', 'user_2022157@example.com', 2024, 'General', '$2b$12$y0JwLpHVI/Q3eLYcecPfvOJWPWlnJ3eJJOaL3LXUTi0/O/ohtSXSy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022158', 'Test User 158', 'user_2022158@example.com', 2024, 'General', '$2b$12$B6TeFHQ8OfIx2rujHq/Hf.BVmYn5LQ727OkP1j/8Gi4Q4LnYKJn16') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022159', 'Test User 159', 'user_2022159@example.com', 2025, 'General', '$2b$12$lpkWvy9K9hup0NAbOVvzh.DZ0cXdu34epJWYXxGGYpVQ8mrp/5zdm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022160', 'Test User 160', 'user_2022160@example.com', 2023, 'General', '$2b$12$.RTQ19vJQMyC0FzrVRTuTe466MQ7mLTP5F9NuejyRcVA4LSaj9aXy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022161', 'Test User 161', 'user_2022161@example.com', 2022, 'General', '$2b$12$a3DHJenpaJXQzf38WT4i1.8XKPVDvIRzmTWS/XGSQZ6t5KdKU1UjK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022162', 'Test User 162', 'user_2022162@example.com', 2023, 'General', '$2b$12$2FMN/7dRmykhlika2hKik.5aL0zo4R1CfrIbDMoXxZrh7uh.M/8KC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022163', 'Test User 163', 'user_2022163@example.com', 2023, 'General', '$2b$12$vHOESDAFG57eNQNSdPcLleFiB2EtgAnrodhkgRHy45WPIye1N4eCO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022164', 'Test User 164', 'user_2022164@example.com', 2022, 'General', '$2b$12$EzNxa1dZJtDoD087t0S.4e2rs0ffsp5R/43U/xqMzEd6pHYvrxoKW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022165', 'Test User 165', 'user_2022165@example.com', 2022, 'General', '$2b$12$49pfa/59JK/BWQjZnfcGqeWu39IKUQVrWWDcW3LdszTkfGHwyllJ2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022166', 'Test User 166', 'user_2022166@example.com', 2024, 'General', '$2b$12$Oe8RbNHJwDVdkRUUSR3tRuDQN2PdR8BW9w9DElKZCUev4ISraJlR6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022167', 'Test User 167', 'user_2022167@example.com', 2025, 'General', '$2b$12$ixi9avNYXoQqooU4l9PoxeUUtoMKHLBjONHEVrVwr9ak4vcrACxEC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022168', 'Test User 168', 'user_2022168@example.com', 2025, 'General', '$2b$12$GrkTgd.SrCshmplzg2j8KOFIOSPGhFbHU/SI5CA0.n1tJVCiP/vUi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022169', 'Test User 169', 'user_2022169@example.com', 2025, 'General', '$2b$12$UCrXC217BOHiDvv3FkK0meYOYLd6zMn4wcS8kBm/F.LgQFnAXPPRS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022170', 'Test User 170', 'user_2022170@example.com', 2022, 'General', '$2b$12$hcww8ms3aWeRLRJWDqDna.G6yECnUwgUb3kydLp9KV6uY5DvOCvei') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022171', 'Test User 171', 'user_2022171@example.com', 2023, 'General', '$2b$12$4AwPH00NFjvR3R5eo3jv4.6CqgJoByTNswb1N4KOd4uqCVMi4KriC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022172', 'Test User 172', 'user_2022172@example.com', 2024, 'General', '$2b$12$8mvpVQgN2mrLADOneYMPz.9Y4wZZGehzVf23JylJwIYCDNVXhRCNC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022173', 'Test User 173', 'user_2022173@example.com', 2022, 'General', '$2b$12$jSIpthgr5TL5NpF3Wx1Eg.zGdU7sVqCDH/77vAfXnA4J8VFNT.wzG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022174', 'Test User 174', 'user_2022174@example.com', 2025, 'General', '$2b$12$Xw.uhl6QnwE9AmljxyA.Pe55g9y7IibxK77QFqPeMjFc4ztVDC9IC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022175', 'Test User 175', 'user_2022175@example.com', 2024, 'General', '$2b$12$9YIhLUsabruYYxlY6/C0Ju/FHiJZvNgbr2bkyq9HbJdtiMyuU.4bG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022176', 'Test User 176', 'user_2022176@example.com', 2024, 'General', '$2b$12$vTLUFyoCdd1UEvY1AXQcf.AEK60PQZOGcDPYRV.WTTdC6CGrxau1i') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022177', 'Test User 177', 'user_2022177@example.com', 2023, 'General', '$2b$12$JDNl/4dFssSP/hYi9e1hLemm48oIgBlLhAxDEzlgmohXg.hlhbGXW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022178', 'Test User 178', 'user_2022178@example.com', 2022, 'General', '$2b$12$8NiE94Ej8vgFy3elPBZrKujndiXWIHTe/X.fmApIerR/9C6XZS/kC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022179', 'Test User 179', 'user_2022179@example.com', 2023, 'General', '$2b$12$0hOVJzYot/2jZ/oho36KGOzkcu/W6iDu5P6vypXKZOCgId5zMZ4CC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022180', 'Test User 180', 'user_2022180@example.com', 2023, 'General', '$2b$12$cqntAdu6XiA3mDNVHo.p7ewxcj.Vkwg.kkT5muA.W.kP6IJEMAvOW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022181', 'Test User 181', 'user_2022181@example.com', 2023, 'General', '$2b$12$1BE.Cr5NFJNJ3..4enNKYuayzNZjXQm0a.B99yo2F3skidE5toGbO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022182', 'Test User 182', 'user_2022182@example.com', 2025, 'General', '$2b$12$wO7PNE6A08LmJO8mPV5IXOjrQw3luhiICaWUD4tALYK6oUYqLOpPa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022183', 'Test User 183', 'user_2022183@example.com', 2023, 'General', '$2b$12$b9csqDwHAOQXaPxAIiYPq.A5ok4Our5En/eaZDkP0d95MPQQfmZda') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022184', 'Test User 184', 'user_2022184@example.com', 2022, 'General', '$2b$12$H2TcdK9T2RFXZ7AKxwAzDe9PaUAlLSBrhiJzqQJL6ZuLvmeWcFqZC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022185', 'Test User 185', 'user_2022185@example.com', 2023, 'General', '$2b$12$sDOBWI/g4o7JkBF8vFi2kOFpiALa.1pNUtZYJtHWjV15kgueQS1qq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022186', 'Test User 186', 'user_2022186@example.com', 2025, 'General', '$2b$12$yQRbqKLJG9DKna81sFA2t.pyYl8uFiCJ0GZUJG6mWvm4segMzcNam') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022187', 'Test User 187', 'user_2022187@example.com', 2024, 'General', '$2b$12$sdGAsdhilK8Z8.Z5VlTH8O4Mrz.S1EiI.b7gAazzh4d9sBra1Knvy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022188', 'Test User 188', 'user_2022188@example.com', 2024, 'General', '$2b$12$SQSzMFR.MqAolqZlpXfpked4foyTMw4Yazq3qni7wG9cety5j/me2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022189', 'Test User 189', 'user_2022189@example.com', 2023, 'General', '$2b$12$oZlYYHpH8Afgz8eeMLs.c.NhlF76jWiENUT49nUQhUM5h7C5m0iWK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022190', 'Test User 190', 'user_2022190@example.com', 2022, 'General', '$2b$12$po0SXDeRTyF79ZT3jiBtG.kgq7xavWDA0uAAASTFpOk0.oMFb0UpS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022191', 'Test User 191', 'user_2022191@example.com', 2024, 'General', '$2b$12$uzYNe9ny1lHnHqAtlrHDtedfYBR6lO5RdlA8WvYzmZSY7/GTKr0jG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022192', 'Test User 192', 'user_2022192@example.com', 2025, 'General', '$2b$12$ONpEmz5uKPA50IzahbpmjeOoKRajQXRfdGvm4ZsLgPqJ3RnZr9AGi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022193', 'Test User 193', 'user_2022193@example.com', 2024, 'General', '$2b$12$cF7WHn8TlPOBawraMv645OvsExSNckZsCrC0JV1AsG/NVodW2LkPO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022194', 'Test User 194', 'user_2022194@example.com', 2025, 'General', '$2b$12$5UA8njbgTuKjANUoNDrn7.iFmWPJvD6IefNQWi.dRCRpTvUT0uw9a') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022195', 'Test User 195', 'user_2022195@example.com', 2022, 'General', '$2b$12$jvflKV0d72yUXr51vVhbTug9jSglE295TYJymwEe9GnRrm7/NHzHC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022196', 'Test User 196', 'user_2022196@example.com', 2022, 'General', '$2b$12$tLAEfVSlj3EicFE7AQqzH..YsY.4.mpM06giFhNinRhoBUKCKyfTa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022197', 'Test User 197', 'user_2022197@example.com', 2022, 'General', '$2b$12$XjqenI8tY0.xeXqdumEzdesjh8zLoZK.B4qjVCBL0MFXEp3wFUaAi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022198', 'Test User 198', 'user_2022198@example.com', 2022, 'General', '$2b$12$GvSCAz9.hDu4rSBaVRcisOF84RM.aINyf/8OIxPU5SLSaYJrvYCNa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022199', 'Test User 199', 'user_2022199@example.com', 2022, 'General', '$2b$12$SjBZuuC/49Z1.N4BcMn88.zw.8dCTxRgH6JMX7ODgUfG5C7Q.Xt7a') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022200', 'Test User 200', 'user_2022200@example.com', 2024, 'General', '$2b$12$NI055ZwP1Bn/amlv99qV1eFDVsH/naCgdMcYwFyVt4seG5RLAW0VW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022201', 'Test User 201', 'user_2022201@example.com', 2025, 'General', '$2b$12$aGkuZXby8HtfcblZaaE5ZuPcHFV6ZJfjZMb9tG3Fylgzst.jLr9dm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022202', 'Test User 202', 'user_2022202@example.com', 2022, 'General', '$2b$12$I6V40exoW5IxphuUe/y6t.72mRE11AyqaM3N0fpr0aj8OoZsw8nxO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022203', 'Test User 203', 'user_2022203@example.com', 2022, 'General', '$2b$12$kUKD42IicFNI62Pp.ub5UO01FdH1mgJPjsOGL6c1ez4tYy0i8YQ2C') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022204', 'Test User 204', 'user_2022204@example.com', 2025, 'General', '$2b$12$RCMe4C5DAOm5lKvI033xK.7De56PGfT.qeB346S5wXtO0NoYxqEyi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022205', 'Test User 205', 'user_2022205@example.com', 2023, 'General', '$2b$12$zyOASfOCvj4B25pCEc3lSObQ1AvNWh6mGU5X14IX2UOIsEegTchC2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022206', 'Test User 206', 'user_2022206@example.com', 2022, 'General', '$2b$12$as0YdB6KYxXKg69xSO8zeeWTuPAidOuex.aFXLKlTe7jzbUCrqtNa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022207', 'Test User 207', 'user_2022207@example.com', 2022, 'General', '$2b$12$LbEvrRiVsckF466zFPgI2eznwSF4OLlnQjaH8Jw1dqmnb2YuS57QS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022208', 'Test User 208', 'user_2022208@example.com', 2024, 'General', '$2b$12$8vlVW3Nwc2tfc.0tWS6Y1esTti.JleR4qu33B3.RaRloy5wRZzdVu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022209', 'Test User 209', 'user_2022209@example.com', 2025, 'General', '$2b$12$6Ck.oesdiB6QZiBxhBlNIO.fmub83.9WFqWLKRUyXBmirlAOEXaBa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022210', 'Test User 210', 'user_2022210@example.com', 2025, 'General', '$2b$12$J89kxcqNnuTtkFrbgiSYRegg/nSWXySe0SEFqqI/1a3R90cHBn1vK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022211', 'Test User 211', 'user_2022211@example.com', 2025, 'General', '$2b$12$awEFJ7gmObSRSR7aDDXsTeEXk/GuP0Gaje/1IHcyAdMZAGW/1Z6lO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022212', 'Test User 212', 'user_2022212@example.com', 2023, 'General', '$2b$12$wKNEKjDqvW/zgF/FUrwV9OAX144tkPeQtfsVHCDnE/5UhfOa.ziPK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022213', 'Test User 213', 'user_2022213@example.com', 2023, 'General', '$2b$12$/oQh6haxho8hLW6N639O6.0OufhulaqKOz9IyPWQMqmadbyJJ206e') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022214', 'Test User 214', 'user_2022214@example.com', 2023, 'General', '$2b$12$H5ID2ZE1EVAlPpsETMOoc.79ZaePVPPf64MrbhtJp.0koAtGTzPtK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022215', 'Test User 215', 'user_2022215@example.com', 2022, 'General', '$2b$12$72O/zc6P1NVL9h.TDCCihuL9gHFtLnH7KGYxDRPjLK0V.Gk8OXH2e') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022216', 'Test User 216', 'user_2022216@example.com', 2022, 'General', '$2b$12$72jeFqit3A.vFbS7HH43BO5OP0UXXt10Kyy2iaA2Ev/qI1kIVspga') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022217', 'Test User 217', 'user_2022217@example.com', 2022, 'General', '$2b$12$ljuEMjVPR5GDngc8rsJZ2uopVinKRF0wZ2zdrzng.lfGQkFnLSPLe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022218', 'Test User 218', 'user_2022218@example.com', 2023, 'General', '$2b$12$4eTKmfdKu.6Z0BGX/J8BsekGMwfRgaIEsJE5loTZRHs/5fKRvZkHG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022219', 'Test User 219', 'user_2022219@example.com', 2023, 'General', '$2b$12$xMnsThbaJaI56MQjJTk.6egK68hbbP39Wxpwm95B7y/4FQuyweEym') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022220', 'Test User 220', 'user_2022220@example.com', 2022, 'General', '$2b$12$WRrADxCh1YzCZO1sU5phbuUPqau2TgeR/.9x9GeiXrss45AyVxUUS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022221', 'Test User 221', 'user_2022221@example.com', 2025, 'General', '$2b$12$YUNBVdLMXWXTPpngo6DVouWlkOPGY0T/xnDDmJ.SHD7/J/7557T16') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022222', 'Test User 222', 'user_2022222@example.com', 2022, 'General', '$2b$12$ST2ZmsEbAwinnGvLeYa1zOet9V56JWM0uUFE28Z3ChmB8utxYoKqe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022223', 'Test User 223', 'user_2022223@example.com', 2025, 'General', '$2b$12$sAcpmO6Yy8dTFvmYR2fBOegug8Ht.6XncetI36/1.1cQuYy6Ia2v2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022224', 'Test User 224', 'user_2022224@example.com', 2022, 'General', '$2b$12$Aqi11MJRJAJFzFVqg7SwjeT3l4hG8ruop2fdzbV3js5iybFWPH6y.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022225', 'Test User 225', 'user_2022225@example.com', 2023, 'General', '$2b$12$gbf5Me4.xpSQHDSEPcJNNeFFantd0jnxwb0jHoZYSYrddsEA.F4KO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022226', 'Test User 226', 'user_2022226@example.com', 2025, 'General', '$2b$12$xFJeMsBAUuo7mRcgYsUsyuQM0.BA1/zi04dsQUMa3js8BR63WkbLu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022227', 'Test User 227', 'user_2022227@example.com', 2023, 'General', '$2b$12$uhR7GXKLG.LJeqngGaUvK.iDQJw6cYi2K9DNjy5nqHqPWYvSw/LJe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022228', 'Test User 228', 'user_2022228@example.com', 2022, 'General', '$2b$12$iOJEHj4Tmr2Dea3eTrRMYeI./7P3lhcJQ4dQLp/rLHwmpYTQybY/i') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022229', 'Test User 229', 'user_2022229@example.com', 2022, 'General', '$2b$12$RwVUbcwConE2SbkzH6c23eJzlD0PLiSlv6ZBAHm5J9YTdmrE588ci') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022230', 'Test User 230', 'user_2022230@example.com', 2023, 'General', '$2b$12$4iR87LtI8b1cxOYmezdfHuRtyevq9Bd201ko6ridFuuXY7uO6OkO.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022231', 'Test User 231', 'user_2022231@example.com', 2025, 'General', '$2b$12$8lBsJPykoiaHMvCqn1sv/.Upfc87c0jMxiwhxA3LmRo6nsSO/zcOW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022232', 'Test User 232', 'user_2022232@example.com', 2025, 'General', '$2b$12$ZGLAoK7y8XoWAWFXSK3RouzGZx.koomeKdGrSCBxKKYYD8PK1.8yC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022233', 'Test User 233', 'user_2022233@example.com', 2024, 'General', '$2b$12$5JYbMpshZKyycEFZOHQqN.0KL5kmIj6ydyHGfEfNg59Vf4Sj8dOHu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022234', 'Test User 234', 'user_2022234@example.com', 2023, 'General', '$2b$12$aWWoeuoz.z4nkMH6DQIaWOoF16MJCDvKNrDUmo/NGwKwv2/fGS39C') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022235', 'Test User 235', 'user_2022235@example.com', 2022, 'General', '$2b$12$qeHdVyHKjjLRfG/JvNBRjeHTnZl0A3fu4eXlu8BMKGYz/9E6.PMw.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022236', 'Test User 236', 'user_2022236@example.com', 2022, 'General', '$2b$12$xojJYr2eu7DhPknR1mYV7.QQnQas1QZ.K34Xar/Djv6JARbKBYgOC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022237', 'Test User 237', 'user_2022237@example.com', 2023, 'General', '$2b$12$CPlDBPNqD86ESmgCESQ/jOoT0E400NzcYPKj7e5aIS5L6rWYeCnMi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022238', 'Test User 238', 'user_2022238@example.com', 2022, 'General', '$2b$12$kOSkMFZyNgS4veiqR6Z1Q.rjh8GzOcHU//Df0EMhuKqmBeYtM/iky') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022239', 'Test User 239', 'user_2022239@example.com', 2022, 'General', '$2b$12$QrDl9xFZsmhjVSGcWBRhqefpL595azbSaBjWFN/PxORJ54gilYo2.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022240', 'Test User 240', 'user_2022240@example.com', 2025, 'General', '$2b$12$5S2AAfG2RXOrSsNp7uchcuK7QR1cGztpmC8HURzA8Ts5dD/LfFRp6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022241', 'Test User 241', 'user_2022241@example.com', 2025, 'General', '$2b$12$TJmDHfEkq/VNj6O5mmM7t.THS.8I0hCWfAOThMDwTCK19uvhiN7QW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022242', 'Test User 242', 'user_2022242@example.com', 2025, 'General', '$2b$12$fYOGb3HbSlDMbdNwX3Ci8.1htMIi/35SesDP5/xCEOfpOGqrTRubG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022243', 'Test User 243', 'user_2022243@example.com', 2025, 'General', '$2b$12$Qe5cE7kL/wZVKZ7VBtS9nuA50G1FSIe0BH9dOssUf.NTsXSc/RH5C') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022244', 'Test User 244', 'user_2022244@example.com', 2024, 'General', '$2b$12$PAZueDuutPy0MzVejmriK.X3YgLtKOVXUcGaxudol5xEFF.iequX6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022245', 'Test User 245', 'user_2022245@example.com', 2025, 'General', '$2b$12$rfLAQmg6cpN0ztwZSVzTPeMD8ETn.5DV/KroSjBjAAEJjyFs28Glu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022246', 'Test User 246', 'user_2022246@example.com', 2025, 'General', '$2b$12$xew3W1VZiFKKpMwncbv9o.T/1ZolMrcI762q8RmJgA13afZSfve1S') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022247', 'Test User 247', 'user_2022247@example.com', 2024, 'General', '$2b$12$ypekGyIUgF8UGVYjF5wed.QKR3n/ZutQt3FfMuF40hl4B1ZDvJsAi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022248', 'Test User 248', 'user_2022248@example.com', 2022, 'General', '$2b$12$/m0RVB.QuVYzuWv71TnhZeJvuf9hlb1nEdn34gS3lr/7sJ.IvwREC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022249', 'Test User 249', 'user_2022249@example.com', 2022, 'General', '$2b$12$ki71H9vX39HhWt7TlvVICO.gsvJLWsFtPzFwrwqypxOU7z9xTvDN.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022250', 'Test User 250', 'user_2022250@example.com', 2024, 'General', '$2b$12$DNy5ZuCubRIdfaBUC6QrUee0IfqZVqL2zkVCwq73mvUIpqvHFm0Ae') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022251', 'Test User 251', 'user_2022251@example.com', 2022, 'General', '$2b$12$J8UIZhQnqUUQII7TK8GDku2u2QWbAdDWEERNhGpEzDYT9KYNHdH6y') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022252', 'Test User 252', 'user_2022252@example.com', 2023, 'General', '$2b$12$xKFkmYkjXDgGGnY0t4w4x.5hGRkh9.Q90paD8/PJetArU9tTG73je') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022253', 'Test User 253', 'user_2022253@example.com', 2024, 'General', '$2b$12$a3.tAtiDeaL/JStUrtI9RO4zAMJwEw0Y6K2wcOz3QUvm.TCt0S.OW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022254', 'Test User 254', 'user_2022254@example.com', 2022, 'General', '$2b$12$tAPfVDunm4gCQjg9F8KuTu8hY5vC71oZr1FoPLLA/24LoCjYFHtFK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022255', 'Test User 255', 'user_2022255@example.com', 2024, 'General', '$2b$12$4O0VzPj3K7b/Y2qm6Z48Ee/yUO5Q1ZHGQ3NS9Sn85/OGZb/UIBvDG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022256', 'Test User 256', 'user_2022256@example.com', 2025, 'General', '$2b$12$BHJ4hlj.OX02RyoLTVNHXO3ZYA768hXa41M45KDkhcmKvphfHPeVm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022257', 'Test User 257', 'user_2022257@example.com', 2024, 'General', '$2b$12$n91bLL68Lvh4UGMbCkE/nOCouLEkJRzWUgQ1HjaFYOJuj3tQfluVq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022258', 'Test User 258', 'user_2022258@example.com', 2023, 'General', '$2b$12$4qINLgYwxG1jEiS9Lc0WSetm3dHs08cTrfjOdlkiTB5f.iVLJIIYK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022259', 'Test User 259', 'user_2022259@example.com', 2022, 'General', '$2b$12$9PzjIGrmXzBQP589eJbuXezoEWr0i/ZvJou32X6k89eDPBz5hgis6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022260', 'Test User 260', 'user_2022260@example.com', 2022, 'General', '$2b$12$QGgReu2eSjGyEaogz62UQOQcKR324eSLagTlD8WIfB4ITU215x8RS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022261', 'Test User 261', 'user_2022261@example.com', 2023, 'General', '$2b$12$TUOiJrmqRLSBSZUucGIcpO8Chtpw62rQx0PjZuyEPzGrScuLyUfoK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022262', 'Test User 262', 'user_2022262@example.com', 2022, 'General', '$2b$12$PIyy1B35B.ycf8w/8DjFkuWYwmaGzvmam2xcKeG4To/toAwBzvV9O') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022263', 'Test User 263', 'user_2022263@example.com', 2024, 'General', '$2b$12$uC8ocSn5f0l1U3h6rVlN/O0hqYhYCBI7Dd/OX3Ggrk0GISKOkLuFO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022264', 'Test User 264', 'user_2022264@example.com', 2024, 'General', '$2b$12$/UUGoA7Ie38UMmbHkWAxouqEnkrDKVkwbxBjMYTTDBsIbogXBLKNu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022265', 'Test User 265', 'user_2022265@example.com', 2023, 'General', '$2b$12$F36kymjCInmAVtLRhKAUOOH.hRH.3Xp.iVE.t/eVt.1hVVaEKiJye') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022266', 'Test User 266', 'user_2022266@example.com', 2023, 'General', '$2b$12$PKweVIUb7jyyKrFumtbsaOvjP9KYajI9TR5pJxLxHF5l7XPU9XKwe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022267', 'Test User 267', 'user_2022267@example.com', 2024, 'General', '$2b$12$wo/fOdxIeKrNGEIg2Sy2YezkBc.xuvN/H3yjsOu20yJWLOXuwFfGW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022268', 'Test User 268', 'user_2022268@example.com', 2025, 'General', '$2b$12$d9cuEbnS0y8artq.HkFWUeIayqiAYRtzv2LMM9cG1gNtPsvmJtrU.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022269', 'Test User 269', 'user_2022269@example.com', 2025, 'General', '$2b$12$ZosD.mm/Mmwqs5uWyjiWBev2cUpPPlQCdYcjSrp/CyR7LyYYog/g2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022270', 'Test User 270', 'user_2022270@example.com', 2022, 'General', '$2b$12$M/qXJ/2.jt6qpzCTLXsvt.Pn9cs9HYJq3esH4pRCYTsHCN5aTxUGm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022271', 'Test User 271', 'user_2022271@example.com', 2022, 'General', '$2b$12$JLUZz/d1yyHXeu/K9Ll0M.hDvSL9IPi4c0cbcPfSnugJ96q0JLqf2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022272', 'Test User 272', 'user_2022272@example.com', 2024, 'General', '$2b$12$7vrU3RoVxMYMyuSpvGWAW.fukLuRl8diZuWaKKZfNk74RBymx/Ybq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022273', 'Test User 273', 'user_2022273@example.com', 2025, 'General', '$2b$12$C/ZIvNhyrhKla1v0DYlrjuJJz6dJLR7uX4wc5LohurdJY0.w/WUzq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022274', 'Test User 274', 'user_2022274@example.com', 2025, 'General', '$2b$12$Cf6/q8ox3CO3po0kKyxjjunLHe7f2RTsyocsj8SmEt.iCix5zN7Uu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022275', 'Test User 275', 'user_2022275@example.com', 2025, 'General', '$2b$12$.F1QmPR5GWm3HBJMPuxoleH4xDMDEqAkirBAXEUZyf4UfhuCuyPHS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022276', 'Test User 276', 'user_2022276@example.com', 2024, 'General', '$2b$12$e6egSWpqcfxIHqrixRwkeeTTZMEXCgdnxPritOV2rXV5nU9bDx6Nm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022277', 'Test User 277', 'user_2022277@example.com', 2023, 'General', '$2b$12$j7GPYFx7ejJzp1p21lhBBOY74LYQveBZi6ICPJcbwa2tDi7ZhArBe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022278', 'Test User 278', 'user_2022278@example.com', 2022, 'General', '$2b$12$guePsdP6O66B82A7MR/cHuErw2YYBpjjUTSgyftVslWW1Hg7SLT16') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022279', 'Test User 279', 'user_2022279@example.com', 2022, 'General', '$2b$12$xXcnHxug9A4yPWdHbraTa.ATwLiniE8UHIhlVSwg8xGVFZGLuKklC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022280', 'Test User 280', 'user_2022280@example.com', 2022, 'General', '$2b$12$UWLNMxsjX5bvcXtjAsearugqPI6osdlO6HCKGo2eo2HvOp5mRgM/G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022281', 'Test User 281', 'user_2022281@example.com', 2025, 'General', '$2b$12$Zf0TnuGJal.bvrdVAWHmA.OIHFbFl8IagrAWEzteq0bSGlMH1VjmS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022282', 'Test User 282', 'user_2022282@example.com', 2025, 'General', '$2b$12$Ou4Jad3a.4gWc1S5UhPod.IW4RiWNiinIkZcd1yH8g8/.cKPApL8e') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022283', 'Test User 283', 'user_2022283@example.com', 2025, 'General', '$2b$12$c85hvX7oQx7.8Cjrk5vfiOGcYS8T.kot1x0SX540Nc5r7S.dmTn1C') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022284', 'Test User 284', 'user_2022284@example.com', 2025, 'General', '$2b$12$FMfqrXxom1VJOfcxZVSedOU6wNmCSdT6Qh4xNW1nXJloVJ3C7CITW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022285', 'Test User 285', 'user_2022285@example.com', 2023, 'General', '$2b$12$/VIdLUeXbReNXb7NG0uZNO6FeUtJbhbKMjVlPiJaC4arUzuPRHNuW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022286', 'Test User 286', 'user_2022286@example.com', 2025, 'General', '$2b$12$5Azl4Rzl2PmzF2lKmuyvs.HUMDdTzdrB.plK9VyMAWOeZ7sryVH3K') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022287', 'Test User 287', 'user_2022287@example.com', 2022, 'General', '$2b$12$HLJR4MWVuYgIevjiXiI3COc/.aTuhwzMN5Wqj0wsVi1qmgY3gZdVO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022288', 'Test User 288', 'user_2022288@example.com', 2025, 'General', '$2b$12$RQvbO3zR9vWWAqAW11CxXueX/1ToF8c5jteg7hxM0.flfdnQb1r1C') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022289', 'Test User 289', 'user_2022289@example.com', 2022, 'General', '$2b$12$DtCZa3etN.5XLbuSZKpQDuGEzDFiO/rHdC0L1d.GX4Lu6aujyCmPe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022290', 'Test User 290', 'user_2022290@example.com', 2022, 'General', '$2b$12$9qKeq22N9C/UpZj2tjM1qOfrTArccL82VJw4SG2po98x1gWVcVMhu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022291', 'Test User 291', 'user_2022291@example.com', 2023, 'General', '$2b$12$ZGA8QyX60MpqX.oOfJIR5Osn3gHcsSRiUwtW3XALwEAqIXZg.y5mC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022292', 'Test User 292', 'user_2022292@example.com', 2023, 'General', '$2b$12$OivTlNaOIgSit4uluR6REei6pehseIct7Xdp.7YPoJTKpxlDUVPUi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022293', 'Test User 293', 'user_2022293@example.com', 2024, 'General', '$2b$12$0BxQL9a8hnNV.QECApo3yeIg6uoTr1XZULgIObIN76bqdNhAU1dsS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022294', 'Test User 294', 'user_2022294@example.com', 2024, 'General', '$2b$12$hGO342XNKliSLi.XftnIjeZymKPENioJBwYhIRNwSkphYvWphas5a') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022295', 'Test User 295', 'user_2022295@example.com', 2024, 'General', '$2b$12$ZgxN/MN/IccHHJTN74EOqOWYwfwkk9avDGyD53qh6RC293mnUsAgu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022296', 'Test User 296', 'user_2022296@example.com', 2025, 'General', '$2b$12$rp3BAB2JmZrLImhEs.e4M.C6eHugxf8KV4bvMtmQ45EVrLQWMj0Em') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022297', 'Test User 297', 'user_2022297@example.com', 2023, 'General', '$2b$12$NK648lnen.AFgL9c.7f8FO98ysaD4KCBuJE8mCKf8CjRj9Y4sDmTC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022298', 'Test User 298', 'user_2022298@example.com', 2025, 'General', '$2b$12$T/JOzLSw5eIiuTbChNbuS.qBCa7ceVP5619q9fc5qL9fn3dqGC0cK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022299', 'Test User 299', 'user_2022299@example.com', 2024, 'General', '$2b$12$oaMoUf9dMAuaRecETXzwZO4vqHsz4CaE2DmD4pa9tH24OsqDTf53W') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022300', 'Test User 300', 'user_2022300@example.com', 2025, 'General', '$2b$12$HynIekyKGGk1VOK0oBrQ/e.1NjxygyTEbTHsxDZ3KphXDwThKFAhy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022301', 'Test User 301', 'user_2022301@example.com', 2024, 'General', '$2b$12$VOggFyaqUAfAyulmVDPQi.iQYlOC60dGJHaCLq0k7d1V4qxoOEmcO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022302', 'Test User 302', 'user_2022302@example.com', 2025, 'General', '$2b$12$42GygAXi.DVje4wWGPXOF.4uJUdCc7e3fyLXlWJC6LU.BlaYJVgF.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022303', 'Test User 303', 'user_2022303@example.com', 2022, 'General', '$2b$12$gkm7UPgtQt2BC4/52MxBdOoiP5sybHOY28/MOEQ7SI6y/wACa0eCy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022304', 'Test User 304', 'user_2022304@example.com', 2024, 'General', '$2b$12$t3AwbJukfD7cEuS.sqg4Ce4OVFEDrPG9mqOzMHRZ0LDQEPq/GDHGy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022305', 'Test User 305', 'user_2022305@example.com', 2022, 'General', '$2b$12$jJL5RtM8AHAcUSocvvLwjOKA3YyT6OG5pDnkID7X46U/LyiELXolm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022306', 'Test User 306', 'user_2022306@example.com', 2023, 'General', '$2b$12$NUXnEuKMLtkdhIuL2t9EsuJSEgMhlxyUVUXrR0s.WkLUquY71gNq2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022307', 'Test User 307', 'user_2022307@example.com', 2025, 'General', '$2b$12$AQI.qCYEHuDfEZFR55QtHeuVwwiUCoO.XBN7Le/2PXXyn2AQsL12S') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022308', 'Test User 308', 'user_2022308@example.com', 2025, 'General', '$2b$12$vqD7hgyN39mradIGTHsGsupyIs5juYYut2yvICDN1I/bMIvA4h6iq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022309', 'Test User 309', 'user_2022309@example.com', 2023, 'General', '$2b$12$tgCs9RZp85MBt7NXdZazDeFmz93sBje56jh/monrzcvjWU2MCFkJm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022310', 'Test User 310', 'user_2022310@example.com', 2024, 'General', '$2b$12$KtWop.Ek/E1NXFG7yu76XOaEl9bvtoeZRxi8zvF/WzCTU65o16UHK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022311', 'Test User 311', 'user_2022311@example.com', 2023, 'General', '$2b$12$1RSNy3T/ssErj1bIBC6ql.J3iIXB9hlvyw46noot8uR6aLDZzW172') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022312', 'Test User 312', 'user_2022312@example.com', 2023, 'General', '$2b$12$7qcfrcB1U1XirVCkICgfaukD2LqtYARdIzVckQWL6X/bEKr00HjR6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022313', 'Test User 313', 'user_2022313@example.com', 2024, 'General', '$2b$12$kH8eIiv.yGVgYhyMfTH5muO59U0SuHycxMKkmZvNXmK4yR3UJ9ctu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022314', 'Test User 314', 'user_2022314@example.com', 2022, 'General', '$2b$12$GNORoQsclCi7O1e.fMxfounMbvQUz5Q5eHu5XX/4U9ffphUpCWEo2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022315', 'Test User 315', 'user_2022315@example.com', 2024, 'General', '$2b$12$kkG9nUSCO.sKBrITuD597e.7VmK/QUEhHQvQ62uLP5hvXrB4Hu2me') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022316', 'Test User 316', 'user_2022316@example.com', 2024, 'General', '$2b$12$Uez07IIreoASagbf8Xndmu.KZ7vna3jcMl6RDU2ej.0EBwVktqVIq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022317', 'Test User 317', 'user_2022317@example.com', 2025, 'General', '$2b$12$mTxUYAegzSnhKemmLSBkK.3xZpYAPwB7XObQsNc3fVFW/47AUui.y') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022318', 'Test User 318', 'user_2022318@example.com', 2023, 'General', '$2b$12$LRkLJdOWRwLLRe2HlFtvZObuFLBO5S5OoITaNNyQqouoEsIpeJHz2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022319', 'Test User 319', 'user_2022319@example.com', 2024, 'General', '$2b$12$AEHp/792y4oe.4TSqmb3Q.qUInoQ9hH.XQGA5E5FDJYoZVWqeZiDW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022320', 'Test User 320', 'user_2022320@example.com', 2024, 'General', '$2b$12$QmHi//3k3WYb6..85GjtJ.V9QKr7oAEpIa2eM45DHMLf9ojcHt7Ry') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022321', 'Test User 321', 'user_2022321@example.com', 2024, 'General', '$2b$12$B4S.yrfQhUE2dt/7ZdO5fODB885TLlUOPDxvWrNorsICJcTogNh4a') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022322', 'Test User 322', 'user_2022322@example.com', 2022, 'General', '$2b$12$qhBIReUWTSumkqzqvSupgO5Hz9iJFKNrm2aHCAZxTgliX1a0Gtbgu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022323', 'Test User 323', 'user_2022323@example.com', 2023, 'General', '$2b$12$L/GFOv.s1ugxgrcsvEsdb.pVsvojK/LsSDR0EVZatl3UWy.pu4jDW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022324', 'Test User 324', 'user_2022324@example.com', 2022, 'General', '$2b$12$0aqVOnnSvyFkS04EO9nIt.DftZg8nErSZynP3xU0AjIajybtX8omq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022325', 'Test User 325', 'user_2022325@example.com', 2024, 'General', '$2b$12$JQBRpuELfyCrNEsCrXy9t.tDfOV5dztYD2PwMfnirG0XV.4Ab4Ari') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022326', 'Test User 326', 'user_2022326@example.com', 2023, 'General', '$2b$12$LYMmSd7ZiCehO/Y1nftd8uxyQGAN8seP3vaqNH0Phgl.8ooKSBbVC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022327', 'Test User 327', 'user_2022327@example.com', 2025, 'General', '$2b$12$lO7eRDkCkvoPMeeMBULoe.o9PbD/siLyYhdPGa26bDYP/0aspD.bS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022328', 'Test User 328', 'user_2022328@example.com', 2022, 'General', '$2b$12$B7DqHZxmVlCmylLlqiof5.zcWAYvLqVaAdxsTuFqHUkrhJ86O3yZq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022329', 'Test User 329', 'user_2022329@example.com', 2024, 'General', '$2b$12$j3w2bvTZtfFPqCPwszh31upoJxOMGg/9OAuyEjks2kuX/H9mJWY8e') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022330', 'Test User 330', 'user_2022330@example.com', 2023, 'General', '$2b$12$v8cHH6cT.hlzQVSUJHq7Y.91Y.Pid5r0DKaF/c29FlpevfuRUMmki') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022331', 'Test User 331', 'user_2022331@example.com', 2024, 'General', '$2b$12$d2QUNycw0zg/MhRizijl4.rqvXfLGATRpoYtAVQrbF88a.MXzLuxO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022332', 'Test User 332', 'user_2022332@example.com', 2025, 'General', '$2b$12$4TzAOI.MpOqy7jpZPpJSlu90XL.C6rppunrwSNdToTfdHw/Nvtegi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022333', 'Test User 333', 'user_2022333@example.com', 2023, 'General', '$2b$12$Ge8/UT8GczvRc0StCC/SLex67cVM0qlOAAceP/uSDr.MK01rKvpu2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022334', 'Test User 334', 'user_2022334@example.com', 2022, 'General', '$2b$12$wmEGqMszA.aZAVgdSv2wPeK8WmAroGUVanMVJ1KH8R33zYR3xV2qy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022335', 'Test User 335', 'user_2022335@example.com', 2023, 'General', '$2b$12$exvGg5OTXaObyr00MyrGteXVze4BBm/cklmyk5v1wQaltWidJlBK6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022336', 'Test User 336', 'user_2022336@example.com', 2024, 'General', '$2b$12$z2vvNpnk24ORkodnh.usfOiKUVXyBBotG5Aiet1utp3UFSauVjmc.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022337', 'Test User 337', 'user_2022337@example.com', 2024, 'General', '$2b$12$hvIl/x.Q5dIPb.I7cO3.COtVbDaC6nR86CBuld6ngITPK6S/3a/k6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022338', 'Test User 338', 'user_2022338@example.com', 2025, 'General', '$2b$12$y1/ppuylAHSXrfiXQk0RSejkbKZwVkbXOyZpiAHApF1.Dy8MWX202') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022339', 'Test User 339', 'user_2022339@example.com', 2022, 'General', '$2b$12$d5Wbs.xmnKvejOukPqaMxugZV0Z2kRRKz275BJhdUijH9nDe9gzFS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022340', 'Test User 340', 'user_2022340@example.com', 2025, 'General', '$2b$12$txqt/8I0OIuf6pD3WvNc5ewyZqpQNI5VrPki6nQvmMwBobmsnmxRi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022341', 'Test User 341', 'user_2022341@example.com', 2023, 'General', '$2b$12$PCRkD.obUVdl/GDaxE1BDuv8eGkOeSWeXynsjctMCaEwbKr1AHt5C') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022342', 'Test User 342', 'user_2022342@example.com', 2025, 'General', '$2b$12$z0g1UNXw8txgt.SvEUIv8.YQ.d5O7ZK5kQ1t/YjGQJWrT0otU4mmq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022343', 'Test User 343', 'user_2022343@example.com', 2023, 'General', '$2b$12$Gp6gbQlUVV517HxLLDWoheqg93.4wJSPGtY381eNpRg/GLTZVWfve') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022344', 'Test User 344', 'user_2022344@example.com', 2025, 'General', '$2b$12$UyKaNzBeUwuhvYJNYsQNf.tuhy7jNzWhTd0/fB0RWrwkwgcNTnv72') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022345', 'Test User 345', 'user_2022345@example.com', 2023, 'General', '$2b$12$P0W7YzDBJUMeZefTbe09e.IcANBwDBg8Rs.0RAEkwyQ/lvbTnWmw.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022346', 'Test User 346', 'user_2022346@example.com', 2025, 'General', '$2b$12$Ts2Nj8sUoeagoCKdsqpX2OSRCaE2iDivgzpABKBK0T53kiPipk4t6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022347', 'Test User 347', 'user_2022347@example.com', 2024, 'General', '$2b$12$D/zCZt0gWdD680AIokNmoeKMlq1lF82y7E33LPuMQkx6TvYuoipJC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022348', 'Test User 348', 'user_2022348@example.com', 2025, 'General', '$2b$12$rway34qJwQdzu2QGCGvesuKw2d/xafqbhkf5Lx8NHKgZEpPfbBMNW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022349', 'Test User 349', 'user_2022349@example.com', 2023, 'General', '$2b$12$2BPEdPvkmtqArXLRprJjNuJec3I33B/PHSgUiP7V5NxB.f.1RB5yK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022350', 'Test User 350', 'user_2022350@example.com', 2022, 'General', '$2b$12$Ph0E/oEO.JzMk8qEKvl1.u7UcixE4KlXGmXu0byXoX0oi2Fb9nkci') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022351', 'Test User 351', 'user_2022351@example.com', 2023, 'General', '$2b$12$CLMqayaNFoEkbdDbe/n8Ouds2yFQSnQMrXX6SKBbqUyuWEQ/oi.Oe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022352', 'Test User 352', 'user_2022352@example.com', 2022, 'General', '$2b$12$.tTGlUUGSaEa/WxvgpFRNuhAhVhZhQwSJwcfDv57QbVLZyouyTMcW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022353', 'Test User 353', 'user_2022353@example.com', 2024, 'General', '$2b$12$JkhyfEgQUy1CzWinzvQQOu7uCpYQlRuywVsfBHQNDUhZondCHRMq6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022354', 'Test User 354', 'user_2022354@example.com', 2022, 'General', '$2b$12$TTZHn/kn2cje1XEjrLO42eHM099i6Gdu/EewzuX8lDF6QIy22jZMC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022355', 'Test User 355', 'user_2022355@example.com', 2023, 'General', '$2b$12$BPOmeZndFP8kQEo/caoBK.PzBZmkWYI.xGkyqLL0bud6quVdgQPmS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022356', 'Test User 356', 'user_2022356@example.com', 2023, 'General', '$2b$12$EV23SYNlYw9WeT1kU672/OuRWIQu7.wylBa/M6cJQf/s00qskivwa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022357', 'Test User 357', 'user_2022357@example.com', 2025, 'General', '$2b$12$6mKNJwa3CVinH7NpBYHkxOXwnA7AQlt23QSZMOxv4HiyPw8/EWMqK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022358', 'Test User 358', 'user_2022358@example.com', 2022, 'General', '$2b$12$wYo5JDtNYVBNCvj4he0o0eTPLtz8BPVANTOmSvZeeWAFVlQqaDqTu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022359', 'Test User 359', 'user_2022359@example.com', 2025, 'General', '$2b$12$zUGWTdNt8GKMxViMVtER1.VyTcD2zZ.7zYn0xiqig7gFCqDkLjOrO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022360', 'Test User 360', 'user_2022360@example.com', 2023, 'General', '$2b$12$7Ct9CXrR8cN0UTMjUIZtN.0m35qrIcKy2TCyD44IZpS02KDQcptgC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022361', 'Test User 361', 'user_2022361@example.com', 2023, 'General', '$2b$12$IGu7l96NPJL2Ehks8mT0Q.fzs215lGh.pnc0c6v70BiJLDRQu4pIe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022362', 'Test User 362', 'user_2022362@example.com', 2025, 'General', '$2b$12$aL1ktKkVBOwsk55m1CI9VevZwUZc5iRk1lPoF.iNmarE13xH4aEh.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022363', 'Test User 363', 'user_2022363@example.com', 2024, 'General', '$2b$12$PC5CTlKu38uqvdasihvEVun1UsBsBiPPYnVEIhf/F4gYGTXvdoNUS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022364', 'Test User 364', 'user_2022364@example.com', 2022, 'General', '$2b$12$TPyw0yRgq27NQASeBd1gfeCz.IAr9KSL5A/KS34saHjCY/6hHKe52') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022365', 'Test User 365', 'user_2022365@example.com', 2023, 'General', '$2b$12$3phn548QPUa1vb39NWt4KO5ELgdPw5gsqIsIgpXntjSdmVBJKkl5.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022366', 'Test User 366', 'user_2022366@example.com', 2024, 'General', '$2b$12$lc9T5uMPsybn73Bb0/p/Pet0Ur1leX/MjMbGAw.TAna/bBqmCLO2a') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022367', 'Test User 367', 'user_2022367@example.com', 2023, 'General', '$2b$12$bTMP8xjdk.5Waq2kA3g9FusxbKO9RxGZDhvCPQeKA/7ksxO68ldsS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022368', 'Test User 368', 'user_2022368@example.com', 2024, 'General', '$2b$12$IOOltLOEdvduymdvqo.mveflklVsNSQGfESCNh3l565PlwNfhy8JK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022369', 'Test User 369', 'user_2022369@example.com', 2025, 'General', '$2b$12$5Ms9kWvaqdf/8jCWugAp5OEk9bllLUhUCW99HtzzzcmhyhNYHMepi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022370', 'Test User 370', 'user_2022370@example.com', 2024, 'General', '$2b$12$oV0sOhu52hMjyJqaMqmJM.bsGeZrSVpDz4vtC4.bJj18IfsC8NfC6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022371', 'Test User 371', 'user_2022371@example.com', 2025, 'General', '$2b$12$hP97VUBsIqNC.dsXSUX4su97EGfd8WWQXzMBF638G1UUnGas0QY6C') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022372', 'Test User 372', 'user_2022372@example.com', 2022, 'General', '$2b$12$4dDRgonMRq9Lx7caBl290uHZgxlna81CEaUuPLJxqdtDTP4dDM0ca') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022373', 'Test User 373', 'user_2022373@example.com', 2022, 'General', '$2b$12$LR8KZ7/6KG4YUTy2MPrtO.kj4/l4q.MHOsMpGD6GnLEqXOoE77426') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022374', 'Test User 374', 'user_2022374@example.com', 2025, 'General', '$2b$12$GOVyMlP/ula1i7L.2ad0C.dtR/FmGzBzaRXA9zv/gds6s6gYlCtCm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022375', 'Test User 375', 'user_2022375@example.com', 2023, 'General', '$2b$12$67qosFym3SUMMumyUD8DcORAqIhodB35wv.IxsooEjOFCRiniCU1G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022376', 'Test User 376', 'user_2022376@example.com', 2025, 'General', '$2b$12$0mfkFlyJq2LKcrYxssb8a.dSeqSyCYiMg2XYy84jINybOA.ttHcTi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022377', 'Test User 377', 'user_2022377@example.com', 2025, 'General', '$2b$12$HTaPPA1xPf.V6jeF2JGQU.cG3tVV4NSw5H11LS2NrTytlCYsaKOlC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022378', 'Test User 378', 'user_2022378@example.com', 2022, 'General', '$2b$12$qc6c98Vc5sdkgtCp2Dd3ZuRLqY1L6u7KsootfGYJbFcnn6zQEB6xa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022379', 'Test User 379', 'user_2022379@example.com', 2022, 'General', '$2b$12$vz6IUZPDc0EzAxe.18rC7uWy0dhlbejZTKVilgG.BnpEtCASJQZ.6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022380', 'Test User 380', 'user_2022380@example.com', 2023, 'General', '$2b$12$kLsfC5p0v2RlBvGHQwgC6e1IE6IjLf1dh7EakvScSK9h.prTfjjtG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022381', 'Test User 381', 'user_2022381@example.com', 2023, 'General', '$2b$12$V82mXBusQlCXE7mkoxnPTOiez9Rcam/6GoifdRLDX/LjTp6gJkYa.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022382', 'Test User 382', 'user_2022382@example.com', 2025, 'General', '$2b$12$xxeCFP9JakGpCNTud0bUoedn8q1lLJieuPeQ0bA99SmXJ44yq8Yoa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022383', 'Test User 383', 'user_2022383@example.com', 2022, 'General', '$2b$12$WXhcGTqkHPF4G/3CKcLRvugvEfmg0oUKEpvmdXZAVkJRpGs3pn8PO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022384', 'Test User 384', 'user_2022384@example.com', 2024, 'General', '$2b$12$1tkvgIcXlNDPBRVMLFgHr.7IefHfb.4kQK9MgZIfSJA0BJTyt81ky') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022385', 'Test User 385', 'user_2022385@example.com', 2022, 'General', '$2b$12$lineFByyEBk/..l480BHceyVnZVmiLIJ87CidocuwfevGricwRYNu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022386', 'Test User 386', 'user_2022386@example.com', 2022, 'General', '$2b$12$PM1iDI3L2hsExYiXPk/T8OooacL2YR9rYaDvMP6Pb8rqWAPq3fTSy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022387', 'Test User 387', 'user_2022387@example.com', 2022, 'General', '$2b$12$Llv2cFf5R6tScD76rPAjveSF89ivlHQaZsIMNGhdRVSYctr8ESyqq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022388', 'Test User 388', 'user_2022388@example.com', 2022, 'General', '$2b$12$qpqppeiD82YWuBDlzEQbUO34Y4lGhkPA9tUE3Luntzs6V30TYLsEK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022389', 'Test User 389', 'user_2022389@example.com', 2022, 'General', '$2b$12$Dlpe1lUUw03BgQ9v8MgUh.kKLkrYqZ0wDKtmcU7QzPvI8P3EJO6S6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022390', 'Test User 390', 'user_2022390@example.com', 2022, 'General', '$2b$12$THpDJfZvEvdYZ34JjXg85.EVW0LSWLIr10/j1N/ypzl0iEDCqP.i.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022391', 'Test User 391', 'user_2022391@example.com', 2023, 'General', '$2b$12$CpxFUUAzP.UngacPYxXsc.nLO87/9N/EIMI0dCJrUcrsLsLuP6QJ6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022392', 'Test User 392', 'user_2022392@example.com', 2025, 'General', '$2b$12$dqeuXJyvNX1o8.ndEYuZrutQ9p2N9GXGFmR7YzGa4QpFSZeDOrXcS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022393', 'Test User 393', 'user_2022393@example.com', 2024, 'General', '$2b$12$iZ7FKi26IgTZSdJtChAKCejWtN8Q9rDVcUKObJ4.v7L2aOMRBduoS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022394', 'Test User 394', 'user_2022394@example.com', 2022, 'General', '$2b$12$udBdIaRy9MGAd865zFvrsuSs.plVfFQ72sMjgWAx6.5s/vmqIiI0a') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022395', 'Test User 395', 'user_2022395@example.com', 2025, 'General', '$2b$12$YeY2BsXyBeZjR7wr60rRjee4ducn2WFOT1YU5ebiF4x7gjb78n5Eq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022396', 'Test User 396', 'user_2022396@example.com', 2025, 'General', '$2b$12$7YIOJb7ig.N2OmCDDaaNN.DVDvwldPV6hvZdd21Q8Atujhpg7lOAu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022397', 'Test User 397', 'user_2022397@example.com', 2022, 'General', '$2b$12$w2cHD1ZS.eCsPssSPRCc/ey7zlgEaDA7kYa9KJO3.2NWHB/IOki0u') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022398', 'Test User 398', 'user_2022398@example.com', 2022, 'General', '$2b$12$kRfLBk28zXQ7oFrbyp7eMe3X08QWTJt5GAI8z130bbCJFJ/vjyqpK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022399', 'Test User 399', 'user_2022399@example.com', 2023, 'General', '$2b$12$Hkye4eh02GvEs0PNA.xLEOqh603yJSnXoOpvarWr/hcxzolIiPtju') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022400', 'Test User 400', 'user_2022400@example.com', 2024, 'General', '$2b$12$rhzfSXD70c.vJksIsWP9K..LtjbY/5zcP02uB8RQl2PpitWoDy5KC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022401', 'Test User 401', 'user_2022401@example.com', 2025, 'General', '$2b$12$89eX92U32NkzDfzWr3jLiOE7X/icM7vwgpPsaxHtvcs8HuSOm6Ugq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022402', 'Test User 402', 'user_2022402@example.com', 2024, 'General', '$2b$12$PCiK/tj.8ELhmX8mG2tsMe8XnqIsGUX3I86m6wVRy1bGlLGE9i0h.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022403', 'Test User 403', 'user_2022403@example.com', 2023, 'General', '$2b$12$ZG8ajJQC.Qo.Hw0YTOks/.cAV.b2pU7P7xPepLKyQgz2/1nJzgLYm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022404', 'Test User 404', 'user_2022404@example.com', 2023, 'General', '$2b$12$CoFEL6Qrs0QSYCde.lMVNeYCHJ08n0H1wJM6gOlMpnYTO0SNDN5eW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022405', 'Test User 405', 'user_2022405@example.com', 2024, 'General', '$2b$12$tjf2m1hCOnAyrD3O30DtfeWi3ecBUvFiAvmHo2mW.oxHjTA2repO6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022406', 'Test User 406', 'user_2022406@example.com', 2022, 'General', '$2b$12$K80HEs1d2r/UHQB2QkYF8OjRfrTft0CKdepmsa1pEBTzFx3WD1kIm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022407', 'Test User 407', 'user_2022407@example.com', 2024, 'General', '$2b$12$JrYRKuECub.x.2Zc4F9C1eDcmRU3Zhbiny9jcNN4El5RWQybBQmpy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022408', 'Test User 408', 'user_2022408@example.com', 2025, 'General', '$2b$12$rdUiWKifYCUq07ad1ze8qOCr0hZeL64EMVi5cxNfFohgSXgxgL7cO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022409', 'Test User 409', 'user_2022409@example.com', 2025, 'General', '$2b$12$fsRbKjGnLhmu57nTRxzfwe/2X2Uk5ldkI7AbCk7BDMMKfCfPfF2yG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022410', 'Test User 410', 'user_2022410@example.com', 2025, 'General', '$2b$12$GCDeO/isu3RwXZamj9Tvm.1htMfPB8YgOtUm5YMOF3JdGlz502XNW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022411', 'Test User 411', 'user_2022411@example.com', 2022, 'General', '$2b$12$XG3bYJ/idqtzViJLsw4Uxeh458Jjz4iP9cz/lmTjzLVfbXhpEZCj.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022412', 'Test User 412', 'user_2022412@example.com', 2023, 'General', '$2b$12$tvQ89HwinXI2pIQpA0qnk.yJzftr2lBL8M/XHZnfeudJYkwnr1Yhu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022413', 'Test User 413', 'user_2022413@example.com', 2023, 'General', '$2b$12$7R2usSC7yo67Kn6qPKCQa.juHECc5TfMGV9pjH14zd25Ue21ctdlW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022414', 'Test User 414', 'user_2022414@example.com', 2025, 'General', '$2b$12$P.UOxjfUINoVPR9TRQf56.aNEaSA9PrBwxbGsfvARdnZXeXvWIKDK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022415', 'Test User 415', 'user_2022415@example.com', 2025, 'General', '$2b$12$O/2WU.NAUCAlp.GDk6qv6OChcxIhGYd6IvnqDiCjB9RWNHLWzOli2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022416', 'Test User 416', 'user_2022416@example.com', 2024, 'General', '$2b$12$TbM5ViuWTs9nEiB2Y7Hkt.KKRdEKB6uRGW930Ec1VsmRXpdymgM2y') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022417', 'Test User 417', 'user_2022417@example.com', 2022, 'General', '$2b$12$uwVLJ8nSEBBA1RUFaRFkmeLN3IPohMVOiXds6H/topeukVkKNCDyW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022418', 'Test User 418', 'user_2022418@example.com', 2023, 'General', '$2b$12$X1WedOURFJE1lZPljg2sD.g45R8dyGu.m6s5.Awe7tgiJNnkB3hO6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022419', 'Test User 419', 'user_2022419@example.com', 2022, 'General', '$2b$12$KLGGLk9QZXEsp0dOqQzCEufDCrimFtxZ9tchlfyZ859KryG/b/WCS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022420', 'Test User 420', 'user_2022420@example.com', 2022, 'General', '$2b$12$xPo7SNa6AtAH9Ef7LGOh2.UFJ5txJ9kYLGmojFxoqe61w7exQk502') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022421', 'Test User 421', 'user_2022421@example.com', 2022, 'General', '$2b$12$dw2qOmtlqvSrK4rmuOvpcuv8cW3ZFmkxtZaMkz.6HswGu9I6XiMU2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022422', 'Test User 422', 'user_2022422@example.com', 2024, 'General', '$2b$12$ya.Y/s1i5Y7LWXOZnGxQwuxyz3nW56qkdhY/N32BhJ/1ZnBsbIjaK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022423', 'Test User 423', 'user_2022423@example.com', 2023, 'General', '$2b$12$h0ozJ3T70Qn.rbMPQKZT2.ycL30tyuKX2IQaUNpB5qx12jBzYntBe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022424', 'Test User 424', 'user_2022424@example.com', 2022, 'General', '$2b$12$z8AgoVMKTwlGOSJ0LYN43.nxgVBpGiEwnNpHZ6JycQFJRydZRECmu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022425', 'Test User 425', 'user_2022425@example.com', 2025, 'General', '$2b$12$lMX3QdhGGvX2D.rN.VJRVepIiRjM4C0rJkQmLRk0CbsuoFmN0yyiW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022426', 'Test User 426', 'user_2022426@example.com', 2022, 'General', '$2b$12$AmUb2.cHJoFZNb5Bzy5ZY.kDoLn6WTVKglR0rGZRcefzvpZDJLPNC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022427', 'Test User 427', 'user_2022427@example.com', 2025, 'General', '$2b$12$KZBwD2RM1p67.iV/krf7fenShxmtHzd4gcsViguiB1q19GEl2w8cW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022428', 'Test User 428', 'user_2022428@example.com', 2025, 'General', '$2b$12$8zPcDQVuVqeQFBdShMhiv.3M3SFLHEwq24H7.cPq/49z573WPVX7C') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022429', 'Test User 429', 'user_2022429@example.com', 2023, 'General', '$2b$12$fIDcTh2LdEiW/e.HWJM1z.SN/nbmyLe4wSa8k1eEYk9DNOMTnKKgW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022430', 'Test User 430', 'user_2022430@example.com', 2024, 'General', '$2b$12$eMomK1.0dPruY/ULE4puxOY3/sJrFy8ZgbaNcm4bVLdy2GEoEAAhm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022431', 'Test User 431', 'user_2022431@example.com', 2024, 'General', '$2b$12$Cwq8eqFeevbeVS4aa2uIAeWUIWcQrUDXn58RcXnFiecUmWXuOZot.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022432', 'Test User 432', 'user_2022432@example.com', 2025, 'General', '$2b$12$A/Kj7yFmocxip.G2Lo7tSOJjwSqtKybC6ga0yZEdr57237IuJI8Vm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022433', 'Test User 433', 'user_2022433@example.com', 2024, 'General', '$2b$12$wOD9znBciv4plLl9GYgpquzMkJJr9aatb2h7MGeotgnaRcH.PwyVe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022434', 'Test User 434', 'user_2022434@example.com', 2022, 'General', '$2b$12$5/lW8Uc1ad/s.qZaRS43LemNRgz2RXP.J0ww7hjM0rfADRjQwCU8S') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022435', 'Test User 435', 'user_2022435@example.com', 2023, 'General', '$2b$12$m/5P0lue9ruo1VHPQm5wqeTAKufud0.c4m1C44It5T5FTlVV7lyKS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022436', 'Test User 436', 'user_2022436@example.com', 2024, 'General', '$2b$12$iLrpI.SdQE/ovZ5ZA8d.8OEYMR2u33gVSwoEmwHeMPyLJsQoR7nPq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022437', 'Test User 437', 'user_2022437@example.com', 2023, 'General', '$2b$12$qKlKV7yWiF0rP1ju1gv/aeDicJPkmimy9BmZD.9KTBaMus9rEbYta') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022438', 'Test User 438', 'user_2022438@example.com', 2022, 'General', '$2b$12$B7BUOX9rQ53opaQv9XVNOeaDKueoFK3gc9JlgL0xGXjdXVD6Jbe4W') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022439', 'Test User 439', 'user_2022439@example.com', 2024, 'General', '$2b$12$415NtGjGOgQ41h0CGoj0H.z4Eg9HVIg3hfXnVrSBJCJwUGLi0/K3e') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022440', 'Test User 440', 'user_2022440@example.com', 2024, 'General', '$2b$12$FUiXhBgBZ2t2cM1fYgrVlON9o9BXYzYLBctW/a9rRgjo4D/VQluMO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022441', 'Test User 441', 'user_2022441@example.com', 2025, 'General', '$2b$12$z17jHeJfqBKNPiGBKob09.D5IEhjnrccSvPo5j46OdYDjAGLZLLYm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022442', 'Test User 442', 'user_2022442@example.com', 2024, 'General', '$2b$12$kjshkTANYRY2P8Ecr5XZ6OghdN0VOUBtDofbFcZqO0utZGzKJlSW6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022443', 'Test User 443', 'user_2022443@example.com', 2024, 'General', '$2b$12$Ypy3TNId33sN.ofAt5YS9u4pIJ12IIBfYm8MiTAsIlXG0LGZi5DvK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022444', 'Test User 444', 'user_2022444@example.com', 2025, 'General', '$2b$12$3J5vIhe0CyRa1ViVtrrtqujVVCEDgVZQ6At.q4IgFYXy0wI.520Cm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022445', 'Test User 445', 'user_2022445@example.com', 2022, 'General', '$2b$12$oX2UCbRA8PDR1kWJpQVIIOYrTJolT0KaggtRoK5yZoU/C2aPoAGKG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022446', 'Test User 446', 'user_2022446@example.com', 2022, 'General', '$2b$12$HB.NcmY5BuLaaw640EaB9eWD7Go0.u.upIQhCq7LylO2NbjxQp76S') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022447', 'Test User 447', 'user_2022447@example.com', 2023, 'General', '$2b$12$exNAE3.yd5zY9VJFQR/F1OHBgBO4LRv.YUzMysVsfAG6qbazIz9xa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022448', 'Test User 448', 'user_2022448@example.com', 2025, 'General', '$2b$12$zFfmLW26eJF0KFqZ9qBdpO6gQinDxQ9uA/TJqGHsGYnhWpauzpHUO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022449', 'Test User 449', 'user_2022449@example.com', 2025, 'General', '$2b$12$L5yuatyh/7qsdAf58Yur.OIKOreGpxBKcIO/feCgf3gAiOaJSQFwu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022450', 'Test User 450', 'user_2022450@example.com', 2023, 'General', '$2b$12$JkRNNGqNEvSfZTSlCFE2mOgN6RWDRLLdYU7G6MPza3.TQad3XJlee') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022451', 'Test User 451', 'user_2022451@example.com', 2023, 'General', '$2b$12$vjyMSq8o27QFhepSYKpFhun2rNBBfblUnSaRHTgdf3aCYRrpeNcii') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022452', 'Test User 452', 'user_2022452@example.com', 2022, 'General', '$2b$12$hDMUZGI..nqy/F02w5KZVupyibDcz5Yq.n8DjZ23l64aWMRgbPa7G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022453', 'Test User 453', 'user_2022453@example.com', 2025, 'General', '$2b$12$SHT/sipDD2RHn.eu9LIfKucQI6AUfwNBhZyp6ITqteiZnKwFU397G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022454', 'Test User 454', 'user_2022454@example.com', 2025, 'General', '$2b$12$uYM4ZmQbuLR4ZuGT.NTW4ul8Q5yFNpGxD3N7DkrZruwQWUFNvxc4S') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022455', 'Test User 455', 'user_2022455@example.com', 2024, 'General', '$2b$12$KgpbVaAB489ZM2yap/qEIuBviQWGkkyUtzVlnk1v0esIOZxTU1zua') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022456', 'Test User 456', 'user_2022456@example.com', 2025, 'General', '$2b$12$Z9OYw9jceCqlyun7wl5DNuQAZNTDavREBealvJqJHVFs7GBpd.jIq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022457', 'Test User 457', 'user_2022457@example.com', 2022, 'General', '$2b$12$erjq4LxmNE.pPvZ383g3xOBPd4egHZEUCWYfWtBTpJ02OeyZWZ9eG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022458', 'Test User 458', 'user_2022458@example.com', 2024, 'General', '$2b$12$g.Oo7Wz4hNcgVEKn7qgja.nbsiCJtS5NqL16/jBhop2WWroSHapSO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022459', 'Test User 459', 'user_2022459@example.com', 2023, 'General', '$2b$12$wwmqwjlfZcpH7hTrW/uzKuckvqlvGR0tLc.N95NwD8HnQ8plDvUyW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022460', 'Test User 460', 'user_2022460@example.com', 2025, 'General', '$2b$12$NJuF7CpGLnjlXqpEDCgsq.BEsKFUotbvcTS795hl6Nj.Yy.rrP5fm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022461', 'Test User 461', 'user_2022461@example.com', 2024, 'General', '$2b$12$JMH6DQbyRg0Uno8vlTsEzOjZWS/jJpf8h8MXhvP.QUjBsghIoscLa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022462', 'Test User 462', 'user_2022462@example.com', 2023, 'General', '$2b$12$/lTbWYKc9KulmRnfSNlQqemtTjS3mKZaRMNtsgu9E21NvcGekclKS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022463', 'Test User 463', 'user_2022463@example.com', 2022, 'General', '$2b$12$Tgz2fg1evqRE9n72uh632.XnPiEGZIG1jM/0msJergZuXQqMZrDdC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022464', 'Test User 464', 'user_2022464@example.com', 2025, 'General', '$2b$12$VWQ0/kFrp4OphFU0JQTcUuAQPWM.pHtXvOi7XaubruipoOG8WN1YK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022465', 'Test User 465', 'user_2022465@example.com', 2025, 'General', '$2b$12$D/VGySpzV5YQp33AzgW1puyF2uIeRbWOtOUAgDAPeCYuwlUZS22r2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022466', 'Test User 466', 'user_2022466@example.com', 2023, 'General', '$2b$12$jsGN11cwGSto7Hn96BEETeSY3pG/qQMiydKbiKw/ishYYYxA7q2e2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022467', 'Test User 467', 'user_2022467@example.com', 2025, 'General', '$2b$12$qJYtskvu0.SSuSkB9Zh3n.iAOGGiPoxudWO4VDGmj4A7L2r0/3Kka') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022468', 'Test User 468', 'user_2022468@example.com', 2023, 'General', '$2b$12$cqHsA6cQlvzaqBJMWdziH.Umfb1FYNzxhIiZBEZSRfbUS7lJJ1YpO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022469', 'Test User 469', 'user_2022469@example.com', 2023, 'General', '$2b$12$9LWgbwp1oaKMYYHg1x3AZO72fIO3Agc68UDFH8iccRt09/52tGZPm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022470', 'Test User 470', 'user_2022470@example.com', 2025, 'General', '$2b$12$EDWGD647E.GlwBgKjHuNrujMyymVGcfcqUAKrUyeDYvt2KoT7jvAe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022471', 'Test User 471', 'user_2022471@example.com', 2025, 'General', '$2b$12$MRc.IPQ0M7.IZgvbJat3vuPzfJpKp/3YpejOEwVRIEu9SUEnMt1y2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022472', 'Test User 472', 'user_2022472@example.com', 2025, 'General', '$2b$12$jZ06O3f7P02J3dS85DEKP.1bNaccaf9H4gUQYTHhpzuSM2otFqwMq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022473', 'Test User 473', 'user_2022473@example.com', 2024, 'General', '$2b$12$4xpOIZIcIjtAfGqJqXEmG.qpACECsT6ainORmYFOnJnNS5LZDcn7.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022474', 'Test User 474', 'user_2022474@example.com', 2025, 'General', '$2b$12$wJ6VV6iDblLIOJ38b/UpXOw7WBhfnj5oHUs/c8tKLdFV3r374aR.O') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022475', 'Test User 475', 'user_2022475@example.com', 2022, 'General', '$2b$12$pvXQrRvOuiFGLQLmH8/iru4ntSDdK9WlRGdwIysOdq.GLlthY5./q') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022476', 'Test User 476', 'user_2022476@example.com', 2022, 'General', '$2b$12$UsBtkG16eX1ceP27gAgJOeGnCAV5FIpuxcPzmPRlWxonZ.VToWovG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022477', 'Test User 477', 'user_2022477@example.com', 2025, 'General', '$2b$12$bB4zHYAcsYalbPXxBta.EOFIMpeNpadU2tChsxmh5bxYURqnfDxg6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022478', 'Test User 478', 'user_2022478@example.com', 2025, 'General', '$2b$12$K0n6edj.ygmZ6ATv3QhGle2mGfqw0fatqcewrYkJui7TVYpImWp12') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022479', 'Test User 479', 'user_2022479@example.com', 2023, 'General', '$2b$12$c81w/3rx9vSHMqp0QutbWuKYAsnFLtfZjG.kEQZqq8Ai.Pv6mxiY.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022480', 'Test User 480', 'user_2022480@example.com', 2023, 'General', '$2b$12$3Cp.aPwRq4HpKInzSsVlMuRndUpmnQ5cujdjvHSf6JBGKM4vmvRha') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022481', 'Test User 481', 'user_2022481@example.com', 2023, 'General', '$2b$12$8v.3WTwztUIf/X7A317mXepZj6MHsEh0bgYKbLS/U5GU579nOBTu2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022482', 'Test User 482', 'user_2022482@example.com', 2024, 'General', '$2b$12$UUEMSnKu4t40R4H44H80RuuuqI6FpXZ/qPQuAuzcJ5sFMD18XYxES') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022483', 'Test User 483', 'user_2022483@example.com', 2025, 'General', '$2b$12$C7ZQfAIIx7IGR8FuSHqZleNbL4QnNIxmA9x03nH0x2JbhOk36WjFi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022484', 'Test User 484', 'user_2022484@example.com', 2023, 'General', '$2b$12$ZQKYlkJLJG.Kpdnu.a4o8OMBa0uUKCpURw3k/bYZx2wBD079AW14G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022485', 'Test User 485', 'user_2022485@example.com', 2024, 'General', '$2b$12$yLvfAf7zNr.Owu7EodVKEudsCQqWsbjC4Joi6mHdyC6vBheQGp/Km') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022486', 'Test User 486', 'user_2022486@example.com', 2023, 'General', '$2b$12$IzDuGKA2GCHGLToQ5ixOT.8RiPNoaVgreIok.5ujZyBrbaASJvSVq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022487', 'Test User 487', 'user_2022487@example.com', 2023, 'General', '$2b$12$6lxkTv/Ng6f787pbjG3w6OZn6XPDTgHqWAQvn9iY1W1YrzG4vPKoq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022488', 'Test User 488', 'user_2022488@example.com', 2024, 'General', '$2b$12$HqiTvmeVuj6jEHZsuZVI0Oizz02mjy4vwjCtckmDDO0fUdg3Wta8y') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022489', 'Test User 489', 'user_2022489@example.com', 2024, 'General', '$2b$12$NMW/Lgxucrblm/Lx3c1Kd.9kMHQgavFbXJomqdU6UvGSMgevfmvl2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022490', 'Test User 490', 'user_2022490@example.com', 2025, 'General', '$2b$12$MiSCdToEiFHpsuZXzSJaGO9KtUcKJfBU6ZPOfIMbNp5tSTfoAPmh2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022491', 'Test User 491', 'user_2022491@example.com', 2025, 'General', '$2b$12$wE8r2yRyRKKPGtBsE17gb.XSnX3Ia1GxBX.y31VEsGcMQXRoJgsuG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022492', 'Test User 492', 'user_2022492@example.com', 2024, 'General', '$2b$12$clYSLmCeiz6imFxAv3zEX.gyx5J5A1Ty1UwEeBO80KNWaZYJZrqQC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022493', 'Test User 493', 'user_2022493@example.com', 2024, 'General', '$2b$12$4MAf16IxxcmVJYXCuGSvT.Qyr9V5ZVgYRvSdzgdsXh1kFoEevPS5i') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022494', 'Test User 494', 'user_2022494@example.com', 2024, 'General', '$2b$12$oGO7Q19a8oIgAZpmGNXdOew9/Lo4kEpCOO3SQq9IBAcogidvH4Y7e') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022495', 'Test User 495', 'user_2022495@example.com', 2022, 'General', '$2b$12$Bx4SmziCBLniL6DtljteMuGToRx/meHbEU54WUvEv9SGX5Mg15ngK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022496', 'Test User 496', 'user_2022496@example.com', 2023, 'General', '$2b$12$XsN9OAgjGmvoAKSlwYG36uqtlHwfWkqexJBtC6.R6FH7YUqutul5.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022497', 'Test User 497', 'user_2022497@example.com', 2022, 'General', '$2b$12$B4Ce.1h7E8xNbKNsUcu.YeZxPqhPxzZXIr3mw1ldcdwrleoYDQlc6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022498', 'Test User 498', 'user_2022498@example.com', 2023, 'General', '$2b$12$7F7s7aa2WzXsJaLv16BsB.MkQYCiqqWFm10l/qp33AbT5N2E4FALi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022499', 'Test User 499', 'user_2022499@example.com', 2022, 'General', '$2b$12$dDdrOj2GzJGWYDPPOOp5IuaPPEG377rzVv8hZqp5iRBrjQ1VBKow.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022500', 'Test User 500', 'user_2022500@example.com', 2024, 'General', '$2b$12$47f1KlWvHKcAnhX5N5nwm.sk37G0gT4CH5ugfX9/mNeYm8zqZlARG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022501', 'Test User 501', 'user_2022501@example.com', 2023, 'General', '$2b$12$MBM9wteGycr4M8mnX0NNn.KJTLz7K.WEMp1o4du.a1lt.8ANnxsSS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022502', 'Test User 502', 'user_2022502@example.com', 2023, 'General', '$2b$12$E5atKa.e9TiiD2St2oNy/uzaJAeS3eTSJn.G9/qZi10ysznDO3N9C') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022503', 'Test User 503', 'user_2022503@example.com', 2025, 'General', '$2b$12$slbOQ2gNOx7.INoHny1LdOvFGrP4N3RzIVR./D0KC4LQfTHsgH75m') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022504', 'Test User 504', 'user_2022504@example.com', 2023, 'General', '$2b$12$ny6AppShvTuJZgPs2mqnU.FDzh9cZEf7LLIU/s0.NPcGjjHg0R49O') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022505', 'Test User 505', 'user_2022505@example.com', 2025, 'General', '$2b$12$oCiF2iwAR5LVryek256BX.erWc6tnbEVp/HksBvG1mAxQKoilsWzG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022506', 'Test User 506', 'user_2022506@example.com', 2025, 'General', '$2b$12$cbtYLMgGdXiHrrLYGL8qI.Dp7n7zjMjopioovUtJ9w/Ye8nonpTy2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022507', 'Test User 507', 'user_2022507@example.com', 2023, 'General', '$2b$12$QZvlc.aTrGOvoqY3qBfWYesvwyOkctkVrrAQU/yFV3Blp8rur6HWG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022508', 'Test User 508', 'user_2022508@example.com', 2022, 'General', '$2b$12$CD67Or160nB/X5G.ONC5dun36vcPrwgCbuB//n6CN8eNhzS0uWFVS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022509', 'Test User 509', 'user_2022509@example.com', 2024, 'General', '$2b$12$rvA06dGeFaGsVr9vle9WH.l0rzUI6WXqqRqATJby/FFIVsmM7tqT6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022510', 'Test User 510', 'user_2022510@example.com', 2023, 'General', '$2b$12$dntL1UWShY04n4io3gCg1ewdFJJ/ogV1WBjjtBOj5IYRPyGvnLfoq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022511', 'Test User 511', 'user_2022511@example.com', 2022, 'General', '$2b$12$4hLcwBcOG.VBlDufmNkBqejLuUn8ImovXaqreA.vx4HRivnqs1vqO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022512', 'Test User 512', 'user_2022512@example.com', 2022, 'General', '$2b$12$OlxgX.ibBmqZYaop6Tf/UuxOXPC5pjuJbfklvFcSv5UvBtBJVb1L6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022513', 'Test User 513', 'user_2022513@example.com', 2023, 'General', '$2b$12$FadzFC3jb6itKO0JzsQbue.I.ACoDq932w4KuKcWxwmRQB9qiYYW2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022514', 'Test User 514', 'user_2022514@example.com', 2022, 'General', '$2b$12$zdNNjvsmcU8bgtD.q2iIwOZ5TZbWgQVoaW4PV2nNrGTU1t5XNwbo6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022515', 'Test User 515', 'user_2022515@example.com', 2022, 'General', '$2b$12$bRZ8mW9AMCU6XWgzRtWe3O48Eyj2rekeKfEgnkXatew8IAbiI0elG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022516', 'Test User 516', 'user_2022516@example.com', 2024, 'General', '$2b$12$Bb2A/xRpXclZzBBHRbNwB.AHHPeXkPxVq5F.zZqgjVRMrCNpY0LUq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022517', 'Test User 517', 'user_2022517@example.com', 2024, 'General', '$2b$12$hTXYl8Q52gKGw/EaaGqyCuG.eDmIhpRU8yM0oHNOH8hPHjwGxHJNO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022518', 'Test User 518', 'user_2022518@example.com', 2023, 'General', '$2b$12$J0jpaZ6e8dTr.6wXlPMuie3Kg8FEO.RLJOuFxFgEL3qYvZSQo/hre') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022519', 'Test User 519', 'user_2022519@example.com', 2023, 'General', '$2b$12$9RmenkBQO/eibvsTYllJC.vQ5o.LIalW8.HG7ZrthPKPRw8FdSgou') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022520', 'Test User 520', 'user_2022520@example.com', 2025, 'General', '$2b$12$p50BxmzA6/Hz2h0qAhOcb.bDcxMuK/9Wqfk1u1CJw898/OlOTWtjq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022521', 'Test User 521', 'user_2022521@example.com', 2022, 'General', '$2b$12$1oh2ZA/YfQsjrsKGKU99Xu94oNf6yXsOiRQZo2/54J/lasObAxsle') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022522', 'Test User 522', 'user_2022522@example.com', 2023, 'General', '$2b$12$Lsf21Az9sB5rNIbfE/f0xuedGQkECZK4HAsr57XfG.64RF6pF7hs.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022523', 'Test User 523', 'user_2022523@example.com', 2025, 'General', '$2b$12$cEyR1GkoCKdsIOFbitOFe.q7IO4cm.2Ch8pyRdh5xWYR7JqZjlDZy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022524', 'Test User 524', 'user_2022524@example.com', 2023, 'General', '$2b$12$9jbqZZ/xz.C3hSSZCKEcdunZ.WeKceCFqEo5kxAAA3v.2HSg8G/oG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022525', 'Test User 525', 'user_2022525@example.com', 2022, 'General', '$2b$12$hwM1QDk2xHPAUEGZP9nz9OqY2WdPBwAKMZlGQbe.cdBdtBCfGrWNm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022526', 'Test User 526', 'user_2022526@example.com', 2025, 'General', '$2b$12$aeQE2M225.K5zMdggRB.z.TxtlSM64TFEti9r67iqEZaPvZh1PU.y') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022527', 'Test User 527', 'user_2022527@example.com', 2022, 'General', '$2b$12$y/4iL.SR10Ih8mUq6PLcVOX9iVCxBqrLksvEYx7JbxWPxJqJC.Amu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022528', 'Test User 528', 'user_2022528@example.com', 2025, 'General', '$2b$12$G1x4G148Nax/2hTqq/wG/uoHsR3IG.Lpb9sBPgSpbKIXdpQCMoVXy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022529', 'Test User 529', 'user_2022529@example.com', 2023, 'General', '$2b$12$/5vTHEXOjkLvWGPZkArdquX66DaDuqsKRot5MHo/pWJ7huf4Q7g22') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022530', 'Test User 530', 'user_2022530@example.com', 2022, 'General', '$2b$12$BCv8xB7nIrpjLNkdegTry.y5ggEZpvBi7XS/Pvf2FTdCJOs8LPnI2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022531', 'Test User 531', 'user_2022531@example.com', 2022, 'General', '$2b$12$YsKl3OUzJAY.cHPlgCyhM.VUm8GyIo5rIl21iZQRc/E/j4sZjCscm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022532', 'Test User 532', 'user_2022532@example.com', 2022, 'General', '$2b$12$VWp333iWMfnbd3f1Q916k.LX8sOjBZM76dLXt0MfvLlHS6nmD/FFu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022533', 'Test User 533', 'user_2022533@example.com', 2023, 'General', '$2b$12$5AHadjXNB1bh.45EjF5NxeMGwvJZMRDHG5OJAZ2EaR9fFCsOlfmIa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022534', 'Test User 534', 'user_2022534@example.com', 2025, 'General', '$2b$12$eEKySkmpuJ16cS6zNwv57e8XpP8211fnmrn2LHnO3/1.LBSsfaBhu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022535', 'Test User 535', 'user_2022535@example.com', 2024, 'General', '$2b$12$etHSg0FIo3nfMYc5Uw6ew.3KTnGLN2GUWUN8nJ6BbrAwyFg2H70Li') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022536', 'Test User 536', 'user_2022536@example.com', 2023, 'General', '$2b$12$BU5BEk6VTrzyMDaIktiomezsI3N2GiRDujwGqtwcXV79GYtS3JL..') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022537', 'Test User 537', 'user_2022537@example.com', 2024, 'General', '$2b$12$fsGHJ8NiLQuYm6dSyiCe2.kz/j4wbSRAsKrASSE7ZxgQtC8jMP65G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022538', 'Test User 538', 'user_2022538@example.com', 2022, 'General', '$2b$12$.e8wXS63tlzJ.ouX6ggqNOHzqCgRNmcMm.nJXpQUZBmhC.JDgGSQi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022539', 'Test User 539', 'user_2022539@example.com', 2024, 'General', '$2b$12$tXkMwmzI9kR0/G49jiy66OfCIhi7I9t.3eH8IGILYDl9sOFKcVJIa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022540', 'Test User 540', 'user_2022540@example.com', 2023, 'General', '$2b$12$.eGmtwnkh4Z.wI1sMsPmV.3Z6CCtx0OlfRc6O9TDJ72Nd1T2uawDG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022541', 'Test User 541', 'user_2022541@example.com', 2025, 'General', '$2b$12$pp3g3xPs2Jg9DObm5o.KL.gvJOK4q97Shot9WeQ.KeGTh6B2qlWl2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022542', 'Test User 542', 'user_2022542@example.com', 2023, 'General', '$2b$12$wtZxd19kwzbQtIAzYpBgSeFM85zSXJRb0SBHLLz4qTbp5FeYxqpje') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022543', 'Test User 543', 'user_2022543@example.com', 2025, 'General', '$2b$12$CFjhavfmSMpwyX.Dhdc.H.680ZeauOyy/o6fGUBUyTtm4ozh1s8mq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022544', 'Test User 544', 'user_2022544@example.com', 2023, 'General', '$2b$12$khRCc5H5q5lobYsvkOy.demElrjBTx7xrKGs1vLDat7VyCLa5nK..') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022545', 'Test User 545', 'user_2022545@example.com', 2024, 'General', '$2b$12$na.N/XOOJdawpeOfc8MoROkJF38XToQuEOr7NEHGLCLt9uhCp7DuC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022546', 'Test User 546', 'user_2022546@example.com', 2024, 'General', '$2b$12$l94r0JbTZhT75LtDwU/6kOhX8tZseGogOgNsr5oO3LpGVnmdJWWUy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022547', 'Test User 547', 'user_2022547@example.com', 2025, 'General', '$2b$12$CakAwKFBB1sxF8VCJes/9evjJgqTrExSynQgB9wiSx.1PYzEKjuzy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022548', 'Test User 548', 'user_2022548@example.com', 2024, 'General', '$2b$12$U/wuwOAhJC1rG6Nu3/jwneh1.m44vpSAB.GpRgfzxUmvw8URlJek.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022549', 'Test User 549', 'user_2022549@example.com', 2025, 'General', '$2b$12$L7IiwtVgMfsHqXbp5HpSuuC1EBO9gxipmAXJOo3/GW35pGNxaWkZy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022550', 'Test User 550', 'user_2022550@example.com', 2022, 'General', '$2b$12$cDil6pGA24mgdJREYqvjXOQclRAT/lof17NUZ/K10v8RC/XOUU5Ly') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022551', 'Test User 551', 'user_2022551@example.com', 2022, 'General', '$2b$12$PWrh4VZg4XmxNtH8U/fhp.tIbyqShjHRnJ7kRGUZWM1ikRTaRtdl2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022552', 'Test User 552', 'user_2022552@example.com', 2024, 'General', '$2b$12$aI74IQ1HRi5DY5NpTCZ48Ou6HSxFsbVWfeVDd2TFN75zIvhlYZrzS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022553', 'Test User 553', 'user_2022553@example.com', 2022, 'General', '$2b$12$0uw1aRWyTXULt5N5Nhj17ezCrDSZpU2p3XrkvoIVpt4ejPxzV3ZGK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022554', 'Test User 554', 'user_2022554@example.com', 2022, 'General', '$2b$12$T3.saMkttoYmfQaj8zsG3eTgY47dTDpFHsnyHPO7JGOP/nsmFKYUy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022555', 'Test User 555', 'user_2022555@example.com', 2023, 'General', '$2b$12$Q9HfOy7Zc97exFAWc/eoWuzLmzM5dgNp5F0b5jgTAjIs72JDL9RZu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022556', 'Test User 556', 'user_2022556@example.com', 2024, 'General', '$2b$12$axKlf6Lgd00njWcKqeNMYeVtxBtsIzJn9luxu8TPnjIS.BTskzUQO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022557', 'Test User 557', 'user_2022557@example.com', 2024, 'General', '$2b$12$5ax0gbWoFT90.kD20NbqwO40X/VH6wBjTScjBWO.knT9v054AfdTq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022558', 'Test User 558', 'user_2022558@example.com', 2025, 'General', '$2b$12$j3xJqFCbeIgTjzAKXiUI2.5.ewv4YGbmSsvAQ0RdK1b/yLISEIbsO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022559', 'Test User 559', 'user_2022559@example.com', 2024, 'General', '$2b$12$HGKw/STQMEMiZwu3CehZaedcwUGADVSZXZuJuznajuy3VKqa9NLI.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022560', 'Test User 560', 'user_2022560@example.com', 2024, 'General', '$2b$12$H0J27OrmSZYpzOlAOm0u7u3KsfXa13V0I5dP6jNvrO77JIx.eMhqi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022561', 'Test User 561', 'user_2022561@example.com', 2025, 'General', '$2b$12$40f/yjnbwi/FVHEA8dsDNOkHLql2S9bwfQ8FRvyU8nsEFk.UaOp.K') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022562', 'Test User 562', 'user_2022562@example.com', 2022, 'General', '$2b$12$QtbDW5opHubLYk7NhvNL3uNG1pHcTORiQoYwcoSAiOGv1EwOihLOu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022563', 'Test User 563', 'user_2022563@example.com', 2024, 'General', '$2b$12$L7rkGzw7yCUkoC9pWka32uOxo9lE4r7dbBZ9PoyyP2GcdGqlEYIGm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022564', 'Test User 564', 'user_2022564@example.com', 2022, 'General', '$2b$12$jkGoaj7RWegvV88JqFoEM.X9FqQnVRKToFZy9c5iJO50mso8m1ori') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022565', 'Test User 565', 'user_2022565@example.com', 2022, 'General', '$2b$12$cLK.zOS4mpw.YjeV86tAAOzTo08yG4Rux7V/ugUPNi3e9EUMfomo6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022566', 'Test User 566', 'user_2022566@example.com', 2025, 'General', '$2b$12$pR1kxJwB7xF0zQtf5fOSz.hqQ2Urviz.Tc4zEjoXUuH.dPdEZtgji') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022567', 'Test User 567', 'user_2022567@example.com', 2024, 'General', '$2b$12$ZA76dBAB/JbGnBb0InH2tO/yfKNJ/XRqtEamX731kNJuT56X61FwC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022568', 'Test User 568', 'user_2022568@example.com', 2022, 'General', '$2b$12$jg6HUHXq2C74hqqLFTIsyO7hVQcQ67X5iThJXx6SIqUi3nm4rrneS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022569', 'Test User 569', 'user_2022569@example.com', 2024, 'General', '$2b$12$UMTXhIRQ8ynpaPfPWP9xA.r09mxJhtdqCsKC3oG0Jm8LMUkhhdYTi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022570', 'Test User 570', 'user_2022570@example.com', 2022, 'General', '$2b$12$43THlVlDwpyZvh.UHrMHwevhvTLdrWfUx4M8kr/fHjHO5xnoZb8EC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022571', 'Test User 571', 'user_2022571@example.com', 2024, 'General', '$2b$12$IzZuOUoIYze8R/PfxgmAeeGnOtmf9HEgr6I8aW9aPOTJvvxp172p6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022572', 'Test User 572', 'user_2022572@example.com', 2025, 'General', '$2b$12$UQsK53asRlcLIKip2kajiO.MMf7A9CdhHDapPIFawp3u6E1iEVJF6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022573', 'Test User 573', 'user_2022573@example.com', 2022, 'General', '$2b$12$0GR7wvv6koBiiKIXtxWxIegqenTXqMDKSHjAjavFJmzp5ul2nPVie') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022574', 'Test User 574', 'user_2022574@example.com', 2023, 'General', '$2b$12$yn3j5or86qjawZVlJa/uaeJoiIhiSDhe1pqnXP52E3e8SyBzNcFKK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022575', 'Test User 575', 'user_2022575@example.com', 2024, 'General', '$2b$12$JH0w6GtaYVNGcWChflX0LuoPKO1Vd00y9k8mke8HDUUkWY70kAPgW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022576', 'Test User 576', 'user_2022576@example.com', 2023, 'General', '$2b$12$xFdj7SxEDC.b0aTj3BfZ6Oi66PjX7WADx8Qb6o5izsnVZrK8lgUSa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022577', 'Test User 577', 'user_2022577@example.com', 2023, 'General', '$2b$12$/M2NKE/lwo1LgDACkep34OVEU5QbD5MNaFhrsXhUw2pF/Wb3tJ0pi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022578', 'Test User 578', 'user_2022578@example.com', 2024, 'General', '$2b$12$RvAW.MPGHqCgVHwsXhT5MOKJC8.vfQE3K0.t2dyQUT9AsoaMSRBTK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022579', 'Test User 579', 'user_2022579@example.com', 2025, 'General', '$2b$12$54wfktb2VyncvGo.u/E3weT9U44epcgrtk9ElGtbJru7SmR3yNOgi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022580', 'Test User 580', 'user_2022580@example.com', 2024, 'General', '$2b$12$EJUeyVaU./7M1ZQmqmjbL.3PLxZUjBRPywZCsRO8v0wo5YKl7iAOe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022581', 'Test User 581', 'user_2022581@example.com', 2022, 'General', '$2b$12$FZ45RtomOT0e1NYqfEbZauZbJiFrXP/3/2.zQ0dSTyxQE2q3N3rgG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022582', 'Test User 582', 'user_2022582@example.com', 2024, 'General', '$2b$12$xZ6VfxXj2pssXJ.XJ1rq2eiTsQmLVqcuI4ZZlZuzQPbXkjDaBhRFy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022583', 'Test User 583', 'user_2022583@example.com', 2024, 'General', '$2b$12$1CJRgx45U0XA/Tfy4/3RauZ5xPsC3QmicvHkVHKX2onfllFi8Nt.C') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022584', 'Test User 584', 'user_2022584@example.com', 2023, 'General', '$2b$12$.PAX2dvp.MjomLxjnrtYvuaB0Pdscd5Quf9HUsNjz8RsjThWUUQse') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022585', 'Test User 585', 'user_2022585@example.com', 2022, 'General', '$2b$12$wDgcMNNUJPEnI5O5/mdEh.xmI005F/7i06JnIIII4uSyh7z25oSNe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022586', 'Test User 586', 'user_2022586@example.com', 2023, 'General', '$2b$12$Y.CqoTJ1tFP4.6QxVRdBguQxzdv.Ic8R1UzDOiaFy76UQEw80wVTW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022587', 'Test User 587', 'user_2022587@example.com', 2023, 'General', '$2b$12$.cOcKK6tkApfX0.ft1HWTO1aXjxLmAo/84TELP2dbhGSozPVgwtgq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022588', 'Test User 588', 'user_2022588@example.com', 2024, 'General', '$2b$12$0EU6tuPx3rik6skN53KwgO2llijhXFjznAWNNTte/2dVR6zxNaXIC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022589', 'Test User 589', 'user_2022589@example.com', 2024, 'General', '$2b$12$xnaeelnB7KcrzRrWzHT.h.o9krHG28DFW9GHGWPD.DXUsm0MCvqKm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022590', 'Test User 590', 'user_2022590@example.com', 2022, 'General', '$2b$12$krCMbcVz9gMdGMLrv7ZLGOVuuAESUrpoFG/ar.L7nq4ZXDcji2q9O') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022591', 'Test User 591', 'user_2022591@example.com', 2023, 'General', '$2b$12$NTd.rrPrO9F7bGiyVZewx.Oap2e96Ef1lIzaVdxOf0r.jqs7e/DmS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022592', 'Test User 592', 'user_2022592@example.com', 2022, 'General', '$2b$12$kyC2X0kaY2kZI3qGX9mRKe0hp19NyZwxKjfMeK/8OsEF/C.1e4H4W') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022593', 'Test User 593', 'user_2022593@example.com', 2023, 'General', '$2b$12$4y7TczaNo1YVIJ4tW7xkf.KEiRb.SmOWKmsdW9Is9Rmvlu/fA0GH2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022594', 'Test User 594', 'user_2022594@example.com', 2025, 'General', '$2b$12$RaRR/ndxQadXM7kMVqoQr.dOAP/jXOOiVd8zQUgl1cEN/0JEgcBFa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022595', 'Test User 595', 'user_2022595@example.com', 2024, 'General', '$2b$12$WnIvBRCQVidKfIr9KhBG5.SgNG6oFKIt/FCMZZ/oEfWDZLZCAHTiO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022596', 'Test User 596', 'user_2022596@example.com', 2022, 'General', '$2b$12$WMJ.BEEFX34/IdsN9snxIOxTLuk6aKE/xyjEcqSfxDMpsK3SgEU.K') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022597', 'Test User 597', 'user_2022597@example.com', 2022, 'General', '$2b$12$WtJKTCGIeYT4yezGouvcm.EVqA4OMTbTGKwZos9tjkqiKXnhcOhca') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022598', 'Test User 598', 'user_2022598@example.com', 2024, 'General', '$2b$12$.Pvrnd8KRCM.t0NxtzoSkOVrv9X1iFbZsco98IoNYXxcM0AJqWihW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022599', 'Test User 599', 'user_2022599@example.com', 2025, 'General', '$2b$12$ZZjI/LHAdS1wTf1e9lC15OTxAuLZ5uTxDA2fNQY1diedHkpTILYAC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022600', 'Test User 600', 'user_2022600@example.com', 2023, 'General', '$2b$12$3moGnUC72YXW85ASvTfInOiigu1HaXIRdreBGiGuR/VkfvlP8S5VC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022601', 'Test User 601', 'user_2022601@example.com', 2023, 'General', '$2b$12$6eUgqYH17/xpeWeTMnLxj.Qqy89KmdBQN00hiKlQVrIhbtlKgaiW2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022602', 'Test User 602', 'user_2022602@example.com', 2025, 'General', '$2b$12$piJ9k297T4ucuBkCd8oU/..H3F9WAG3pkPtpIQbElSr6h0pITMAeK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022603', 'Test User 603', 'user_2022603@example.com', 2022, 'General', '$2b$12$I81Zr5riDgyE76GZ7tqMqubBy8LfzHhaWJqXa7FIfLh7zUK9SoSii') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022604', 'Test User 604', 'user_2022604@example.com', 2022, 'General', '$2b$12$BoeKcCGqO5ZGr0ioFhdCv.42w5vn4ay.rFvknfB4zflT2i1Sxccpq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022605', 'Test User 605', 'user_2022605@example.com', 2023, 'General', '$2b$12$F0vQPPQbWdRK4nDrcKa7iOpSPjtCm/EXMEOvAEQyWGFwijIcFNNe2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022606', 'Test User 606', 'user_2022606@example.com', 2023, 'General', '$2b$12$TwYea.PWiHOLYxr070E4wejLTQCZOr/8r0FbrFKWiIGDn.uyhNrta') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022607', 'Test User 607', 'user_2022607@example.com', 2023, 'General', '$2b$12$hjf5ddveakKaCIRHZ2u/su5ndB/ks0AfO7x5cLrhPAt4yUKP.df0q') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022608', 'Test User 608', 'user_2022608@example.com', 2023, 'General', '$2b$12$kkqPRw59YlKgaHKLg9aLXeuMufHmEJ1Mf2MSblYMfW0uPN0t17fcu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022609', 'Test User 609', 'user_2022609@example.com', 2024, 'General', '$2b$12$e6tcrKSFeDh/hik0g0Ioyuizu8oRgl1StezZ5xOb9a4f8CEHwXxle') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022610', 'Test User 610', 'user_2022610@example.com', 2024, 'General', '$2b$12$x/5ZW1A0x3M1hbBTI83hKOQHPvwekoSlpB85Jrd2K8rZqScet7TLu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022611', 'Test User 611', 'user_2022611@example.com', 2023, 'General', '$2b$12$DN.hWZlWq2R4OwjDuf0MReVnO3F3UvV4hXadOTNyG8ZBxOtzqxiXO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022612', 'Test User 612', 'user_2022612@example.com', 2025, 'General', '$2b$12$1ES7y0hzp6yM5crAALVHwOKWOUeJhkOAXd3.KJs4LR5EYFDB4aS.G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022613', 'Test User 613', 'user_2022613@example.com', 2022, 'General', '$2b$12$GCkNhDB5WMMRJ2HXnm7B1OvIAhZV.3Z2Vt/l8d4vyIxCcUYKetMX2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022614', 'Test User 614', 'user_2022614@example.com', 2025, 'General', '$2b$12$atAndboyrtc6L.Ew1xC2YejiA8BIo2EmztWIQPrbttMWuQfUvmDpi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022615', 'Test User 615', 'user_2022615@example.com', 2024, 'General', '$2b$12$U18FwlSDu8f2CGvI9hABqu8ECAvq5t4XEFtM5K/fXTokiyFmlaSCe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022616', 'Test User 616', 'user_2022616@example.com', 2024, 'General', '$2b$12$9w3ZrNpkdY3wmsTsKzDoB.vSPMUO9iuQgJPYgoH8AnEIPZMBwc0ve') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022617', 'Test User 617', 'user_2022617@example.com', 2024, 'General', '$2b$12$r/eW444RaCYCCcL.Y2kqfO8aFbnda/Qj.o.7psHYFV9TmblePTmDO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022618', 'Test User 618', 'user_2022618@example.com', 2022, 'General', '$2b$12$vKKo0HVClbUlWQILKJFwD.IU.lZ/Skg6rMd1u8mKHGSIJmnWgyfXW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022619', 'Test User 619', 'user_2022619@example.com', 2023, 'General', '$2b$12$YBcSGfmHXEX5rG.6H1LaWetTvbTRvojWYrCeYsS4iynETxetXpwTa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022620', 'Test User 620', 'user_2022620@example.com', 2022, 'General', '$2b$12$iScobM.Z3aUmFnsfzyyzaODUvSHFS8T5ntbU9jVUW0n96666c3KMG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022621', 'Test User 621', 'user_2022621@example.com', 2022, 'General', '$2b$12$gMVWj0U4eE5oBbzAxbX/QOg6Q.Kq3dSlpYsNHAOpbtum.lsORFg7y') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022622', 'Test User 622', 'user_2022622@example.com', 2022, 'General', '$2b$12$OZwKRUoT.KftIuscp7JkxeT5SSMepBrvGUCBqIvbZimZfxbmWnd5W') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022623', 'Test User 623', 'user_2022623@example.com', 2024, 'General', '$2b$12$ecEJwYU4ZSEAwGjXOQcBPeCskNC6xujdmPkECpzoAF/pH2jHT1ygG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022624', 'Test User 624', 'user_2022624@example.com', 2023, 'General', '$2b$12$.Y9IzRKQ54i8WDZozi/RSujmGswk.9Xg3Ro95DvdEGM.xg.7fHh9u') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022625', 'Test User 625', 'user_2022625@example.com', 2022, 'General', '$2b$12$vxnZsyqkgPeKwO9ftrp5t.jMmIfAyvWWLdWLZoTGucZThKAEjBYQy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022626', 'Test User 626', 'user_2022626@example.com', 2024, 'General', '$2b$12$x/ct7PHR/o6mjlxBN9vMx.frjtuqF25twcQkibpRy/ea/38e2Yo2u') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022627', 'Test User 627', 'user_2022627@example.com', 2022, 'General', '$2b$12$w3FQkSdFuy/sfSlpz1rczukk4HTSxcyPMx7lwincs8.TUZugh968u') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022628', 'Test User 628', 'user_2022628@example.com', 2024, 'General', '$2b$12$10Db8J8p/UAr/Eh4FKouXesR.GuQCq59m3Fpr5rgPk17vm7bI0erS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022629', 'Test User 629', 'user_2022629@example.com', 2025, 'General', '$2b$12$ONBUXk/cP9JEEy7wik.8mOZYoT.99jlHsCHnsqEf5Wa7.miutJPVq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022630', 'Test User 630', 'user_2022630@example.com', 2024, 'General', '$2b$12$u0g.Ut29f/sOMWX/CczvyuL8GA8st8zZ5Kh2aOiD2JebAuWmb8X/y') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022631', 'Test User 631', 'user_2022631@example.com', 2024, 'General', '$2b$12$wkOKj6FIaRRS3/6JOTS7p.gk9gq8EmOOK4QNMsej9B9dCnjETzDJO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022632', 'Test User 632', 'user_2022632@example.com', 2024, 'General', '$2b$12$3KxVZsGU/1EglVpUbRq2Qu67XYcpHr9dJ7uZ8jidwiugWL36gPScK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022633', 'Test User 633', 'user_2022633@example.com', 2024, 'General', '$2b$12$xiUL1jPL4/AyrwLws6GOPO8AKn2dIT9v7qMSLwJRsNP.PmgszURUm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022634', 'Test User 634', 'user_2022634@example.com', 2024, 'General', '$2b$12$TYzZkh6fD8QB3KYmJtDzXe50x4qCx1zBOutGlO3.9l9qLVbAo3bSK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022635', 'Test User 635', 'user_2022635@example.com', 2023, 'General', '$2b$12$IZ.yqXejdb9P84yf9DlvHOKcqSOMXCv/0n6K75XMiZ5zaDEFSFfWi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022636', 'Test User 636', 'user_2022636@example.com', 2022, 'General', '$2b$12$1PXBr.UGlC7412T2TBHu5eEyTfdIwgOTOJRlfmp.fUVIE5OxU/uuy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022637', 'Test User 637', 'user_2022637@example.com', 2025, 'General', '$2b$12$rv04uSSr1dQwtJLqATYaMOvkPh2mUT3HMWVjRWVrjNrefOe4JIZjK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022638', 'Test User 638', 'user_2022638@example.com', 2023, 'General', '$2b$12$IyAasjGL/vVQVYGJLLiD8.WgZaLKP1S6P8xpGGnbiNXUkUgMKec4i') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022639', 'Test User 639', 'user_2022639@example.com', 2022, 'General', '$2b$12$kKJfKKauEbjWECNJwo0B8e3XSZjAXaBCwPDb/7kGg8J5wdK2f0YLe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022640', 'Test User 640', 'user_2022640@example.com', 2025, 'General', '$2b$12$CXwix6Y9kwBw7GfJjjbvqOi31rZjYpvFGXrSy9yI3EEFtIEEMZfeG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022641', 'Test User 641', 'user_2022641@example.com', 2023, 'General', '$2b$12$l1bdBCK1ws45SPZfykH.KO7uoCpxCBPALKgpZtDkU4FkKWF0eEe6G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022642', 'Test User 642', 'user_2022642@example.com', 2022, 'General', '$2b$12$bdxOqgLXfAk22Y/fxwP7g.Re.znlnFO/T4LDKtccIPrt7gJONCkKi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022643', 'Test User 643', 'user_2022643@example.com', 2022, 'General', '$2b$12$kfb.GDCcg2bCkoXazjk/1.rwqs4CgK/cgXGSyMeh0xPyaZ4UyQEXy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022644', 'Test User 644', 'user_2022644@example.com', 2023, 'General', '$2b$12$DQ3kHE8daHEe.Il5Uc4mcey2x7wE9wGlkTsW04/wG2f7PJwQ4AXt2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022645', 'Test User 645', 'user_2022645@example.com', 2022, 'General', '$2b$12$Lirhad83mkbtIe1OV02ZnemmrfeNhr0D1UYwYwPf//ZXPdBNVM2Wu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022646', 'Test User 646', 'user_2022646@example.com', 2024, 'General', '$2b$12$DiPhcBNqKyBrMceZAdGVSeIO1lCtXck2ocu/yQFmw7Ipi2Kr6W0J6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022647', 'Test User 647', 'user_2022647@example.com', 2022, 'General', '$2b$12$JWO8psYUATKUkTJc3QrnQukulG3N8QD7MRtgmYXbEwM/LlDdk9OG6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022648', 'Test User 648', 'user_2022648@example.com', 2025, 'General', '$2b$12$YwSAvSFlSOB0SUJ.x4jcgOiTseuActpGLNqL3pxJpeqtp1ogisMXe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022649', 'Test User 649', 'user_2022649@example.com', 2025, 'General', '$2b$12$H9/Z7NkU9DlL2zPo4eBpy.KmpI3FofknQ3h6NKFrB/NzhxssSxyl6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022650', 'Test User 650', 'user_2022650@example.com', 2024, 'General', '$2b$12$9x05ZXwCIavJbVZEzgYh8uHlZCSsRwNzY4xCJDSDJfGJz3t1BTT3u') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022651', 'Test User 651', 'user_2022651@example.com', 2024, 'General', '$2b$12$5rBe7L1VxH/MOxA5nZPpmOjdsh16BOTWCEjMba3vIL9aqPMTB6sOe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022652', 'Test User 652', 'user_2022652@example.com', 2025, 'General', '$2b$12$lE3lwN4qZL9AE18k2Bqi4Oowiuxohd2DKFou8I/tWKDXI6TbElYXS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022653', 'Test User 653', 'user_2022653@example.com', 2023, 'General', '$2b$12$6xOY4RsbZBmfIE4d4dwzD.JppRoBqt.ztDU5p2QTYfIEBKPwdiKkq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022654', 'Test User 654', 'user_2022654@example.com', 2024, 'General', '$2b$12$tXkUca0wC4QPMQVMq8t9zeRmM0.1iePYSGmChA0.4t0c/GpMS1Wsa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022655', 'Test User 655', 'user_2022655@example.com', 2022, 'General', '$2b$12$esSKwvzq5FXgrQhgQ.RQHOf58f.KzKocPF7/kc2UtdnRvcZErv/FW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022656', 'Test User 656', 'user_2022656@example.com', 2023, 'General', '$2b$12$apjW6yuKmF/WwuV7.4qiY.xEcq4T1FHu7qplaAY.e7yyJX7e1RCJO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022657', 'Test User 657', 'user_2022657@example.com', 2025, 'General', '$2b$12$R5fqjbQwOM2aqh9XoFRGNOlesTG26TNBixiGLSOzSyaTl1gyyCF8.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022658', 'Test User 658', 'user_2022658@example.com', 2024, 'General', '$2b$12$ubjTj0IJB8uNlAAJdL3X1OYPwDXOLCiRsSV8W0zAkEv8STaHlH69W') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022659', 'Test User 659', 'user_2022659@example.com', 2022, 'General', '$2b$12$k/dm/ZY7kNpvK2r7HuH1oed8h8a5SpPQWOCrExcSjIk89AUcobmvm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022660', 'Test User 660', 'user_2022660@example.com', 2023, 'General', '$2b$12$tfef7hV15gkoAz0wHJIgpeF6dz.VFDCQY1qc.9cET1UhVOXPNxFB.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022661', 'Test User 661', 'user_2022661@example.com', 2023, 'General', '$2b$12$0P9RSk8aoiC32skVD6PmJ.PLdtJE57KGh6w6SpVPFYUgBIho4iJ9i') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022662', 'Test User 662', 'user_2022662@example.com', 2023, 'General', '$2b$12$lkifdTZS2TK.fbyiZJaUHubt7p5b2kDDgf8HMqx33IKDlJXBnccGe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022663', 'Test User 663', 'user_2022663@example.com', 2022, 'General', '$2b$12$2OHF7Z0AEPQZilVnjCi1fe.UrWvPoeTpBPon3CodAB8Th5zMiFoXe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022664', 'Test User 664', 'user_2022664@example.com', 2024, 'General', '$2b$12$lrsMrhGP17.nf8duq1rpzeljQPxrb74rB62b.hv3SOSKepvBV8MBa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022665', 'Test User 665', 'user_2022665@example.com', 2023, 'General', '$2b$12$rhEYsc.k/gGDnIX/bEg2/uO.DNQXHvn9HuZgktX6kTifamzdY1MWS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022666', 'Test User 666', 'user_2022666@example.com', 2023, 'General', '$2b$12$z6UZAR9Xf8mbUB3KnstVaeOR4gIiBRwHmSRBE4Cgy.MRPTg9XeF8K') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022667', 'Test User 667', 'user_2022667@example.com', 2023, 'General', '$2b$12$yzdD7Tr2KSCuCNFJ.9VHjetDDgUos8tfL1eGwcjtyuZnVKGEFKBLC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022668', 'Test User 668', 'user_2022668@example.com', 2022, 'General', '$2b$12$KPT030xNcsOR/0ab2bAQEexqtR2pfTCxa/t4O6Q4JAG/GJmzsVUSW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022669', 'Test User 669', 'user_2022669@example.com', 2023, 'General', '$2b$12$JX3zygWuLFu4jK24OJODhuNlR2pcG.RfjVIdch37FKYSoQx6i/HDm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022670', 'Test User 670', 'user_2022670@example.com', 2022, 'General', '$2b$12$FegXxyAqkqDaKOgRG.4QW.lxr9cGvYKB5IJoQAqUJb9BfTP3jc7bq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022671', 'Test User 671', 'user_2022671@example.com', 2025, 'General', '$2b$12$78SXbt0Rm3boO6Vaks.59eztdeKxe3CuTAOa4PMV5jZ39jWX.1hD6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022672', 'Test User 672', 'user_2022672@example.com', 2025, 'General', '$2b$12$yc1foeL3iI6dxgNgMXySDugjA5Dw1RS4SluhD4myugGOJjPqP.m6i') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022673', 'Test User 673', 'user_2022673@example.com', 2025, 'General', '$2b$12$y3TlU/7SpB8.c2SyhIoTE.TSY0YAaK7fy7QRs7irnEiKqSOcJAX/O') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022674', 'Test User 674', 'user_2022674@example.com', 2025, 'General', '$2b$12$6mcc8Rny7tDR9G9bvBEguurxKsMCOy27plXhcJY3YQiMgkWv4W9FO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022675', 'Test User 675', 'user_2022675@example.com', 2024, 'General', '$2b$12$5TY3jnSl7mwIGNAyveX.r.nMPHsiZn6niU2s5CcPu8EKDQO78w2Ta') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022676', 'Test User 676', 'user_2022676@example.com', 2024, 'General', '$2b$12$amiX0K.wWzU9qNSrjuKzieObBgwwt82a6nRaU7OSPPRpWniyyLbMO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022677', 'Test User 677', 'user_2022677@example.com', 2024, 'General', '$2b$12$qpCVd5Uqjd0hXlmyCVWj5.WcNJakEiB6kSPvZuWd/BJzjh3AbD0wa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022678', 'Test User 678', 'user_2022678@example.com', 2023, 'General', '$2b$12$fFQvTurLJqvmlinoqmLq.uXD5QtLAhegKtbLPk7Qb9VGZre1EBY1m') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022679', 'Test User 679', 'user_2022679@example.com', 2022, 'General', '$2b$12$OeTYBhlvJgd8sPbLx1g5V.fNDuia8r9md2Jv5nn0aQXBzbxeydp6G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022680', 'Test User 680', 'user_2022680@example.com', 2025, 'General', '$2b$12$dA2u3GS6unFvR2IBQHYW1uBw6FsC5jUHT8AnpC1wYze8FPOulDF9G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022681', 'Test User 681', 'user_2022681@example.com', 2024, 'General', '$2b$12$1dxZHyQWZA3Vm2.GaxGAm.YS.geyLexSCXEcDA7uGcfsIW4iJQdWK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022682', 'Test User 682', 'user_2022682@example.com', 2024, 'General', '$2b$12$lcR9NNJ8yQIZ3Am3V1yL/ORtgi0wXWjQW6qYyx7xXNM9yeOlfPMcG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022683', 'Test User 683', 'user_2022683@example.com', 2023, 'General', '$2b$12$CW2THUqwqtI/FA9wUdK5hOihhU/jczqyU19qdtXaBisKjyHqTYJJK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022684', 'Test User 684', 'user_2022684@example.com', 2024, 'General', '$2b$12$IxJa1UppxHaAPTyyNWWx0.pe30tuAckqY4etT3kq9/E8nEYU.5zhm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022685', 'Test User 685', 'user_2022685@example.com', 2023, 'General', '$2b$12$q6Hxo8SlT6dbdOSAAdioIeePUBFyL9Eeyup8B.LIsdQm7fA/9zjKu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022686', 'Test User 686', 'user_2022686@example.com', 2024, 'General', '$2b$12$dTTE9gJ1b0whWv86yhsgouVngkVMQcopt42iu2BuObaG81XRuR62a') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022687', 'Test User 687', 'user_2022687@example.com', 2025, 'General', '$2b$12$5K28VBjtC4GrrWTBcFlV/.bW90Yxi9TpjpmA250Jhb/raHMmje00S') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022688', 'Test User 688', 'user_2022688@example.com', 2025, 'General', '$2b$12$a7gjGzB66GY6iKLeRPwYGuO.qHnm3vPFH4W44ZK4QBis25a2uH/RC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022689', 'Test User 689', 'user_2022689@example.com', 2025, 'General', '$2b$12$DE33Cba8jAGugphn9hs.5Of9N4bJQac8xMF9bSaA3O9B3f/zCFKie') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022690', 'Test User 690', 'user_2022690@example.com', 2023, 'General', '$2b$12$Z0Ck5HfYLmPUsPIUHxyvMev.GLmuziJoo1BcMR4gVtBaxzUHCBTW6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022691', 'Test User 691', 'user_2022691@example.com', 2025, 'General', '$2b$12$.SJ8OtsCOE3o8ei.Hf4jl.S9Ex2yyeaQWZS3BA5ue96Cj2YYABAW6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022692', 'Test User 692', 'user_2022692@example.com', 2025, 'General', '$2b$12$JC.qNowK039ZceRzgU0uielWwtaBYGwIMhepZ9PS8sEGLXN6SU8K2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022693', 'Test User 693', 'user_2022693@example.com', 2023, 'General', '$2b$12$mylUDennoSUS/cU.Fdiy2eyoHDEkjM9YtqTIdgw3op6qz78ZGQNp.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022694', 'Test User 694', 'user_2022694@example.com', 2025, 'General', '$2b$12$dqIOjTrGsQhfK7QiWZ31z.fScHbFmutYv7OKBmbosLZ/zsvrSvIjm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022695', 'Test User 695', 'user_2022695@example.com', 2022, 'General', '$2b$12$63rJgcQPyfmaltsIdEmU0.hHy0bQaqo5j6Tno5OSlSd/7tet4MPtq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022696', 'Test User 696', 'user_2022696@example.com', 2024, 'General', '$2b$12$H4HOW6W/eSpr.xYL9jrxJ.A22U5Dba5yNt0uzJlHAuiBSo/g4hFqm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022697', 'Test User 697', 'user_2022697@example.com', 2024, 'General', '$2b$12$NVKblfpyhfJo6XTqXmXrduCObZfXCGzI9G5hv863BUPRHh6QcvYd6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022698', 'Test User 698', 'user_2022698@example.com', 2024, 'General', '$2b$12$zf2.c95lUXniZkq96zTKmuZZ8dJ39Uj7BHK33f7YDBhSysFhurfL.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022699', 'Test User 699', 'user_2022699@example.com', 2025, 'General', '$2b$12$foLevHYINn6gFUV7/QRTcevzSml3/sHEqnaI1Z5RbHMvW17lKZ1IC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022700', 'Test User 700', 'user_2022700@example.com', 2023, 'General', '$2b$12$JOeJ7SJqonDtLV6TdLmFquC064vHY6YAuuR04I16rGHEJsB.K.Ad.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022701', 'Test User 701', 'user_2022701@example.com', 2024, 'General', '$2b$12$.iWZVs/nKoBb7FaI10EalOisDFnWKW/zITr2u8OaskBzR8VZ/NuUC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022702', 'Test User 702', 'user_2022702@example.com', 2023, 'General', '$2b$12$r4333kNgCNhksGVFJkRBzO.aBx43xqClA2ARQHnzt3NaLx2bCC13y') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022703', 'Test User 703', 'user_2022703@example.com', 2023, 'General', '$2b$12$yjxu7d4HDEbuCP1zL6orpuNZkz05ZNPPphkscgJifMDrwZCI/75h6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022704', 'Test User 704', 'user_2022704@example.com', 2024, 'General', '$2b$12$/iT/KG2J8iB1yEqXMNsDpOv2f1FhbHBpE14D517yyAzQncMI4PafC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022705', 'Test User 705', 'user_2022705@example.com', 2022, 'General', '$2b$12$mxZ0sZLsG5Iehh2O9j5oTePgevRgXBvDxWfuwIu3hZ53po5wTDlKO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022706', 'Test User 706', 'user_2022706@example.com', 2025, 'General', '$2b$12$yvS2u5TVstF/DIlTvPFvEuOMI5Nd/7dYf67COLdoCjT2N2d6uh0i6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022707', 'Test User 707', 'user_2022707@example.com', 2024, 'General', '$2b$12$3RaS0Nh7NWVcj4lwMzziG.pHxf8vfGb1.nHIy0JJK6m4HUXeS9CKC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022708', 'Test User 708', 'user_2022708@example.com', 2023, 'General', '$2b$12$Y3ZThNhTaaQqydcjDRRiseeiXZkHAysDlPkoS7ckZNcErWgOpY1km') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022709', 'Test User 709', 'user_2022709@example.com', 2023, 'General', '$2b$12$eaa8m6VxsLcto2tadPvnnubRAszv3CmsTqabyQwA4S0LRTIxClm9e') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022710', 'Test User 710', 'user_2022710@example.com', 2023, 'General', '$2b$12$lfnVW0mgsPcDz1DhOeKryeTllT10zMVJNlY9KA3NGNXqwBWyue81y') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022711', 'Test User 711', 'user_2022711@example.com', 2024, 'General', '$2b$12$dtlWlUJOIwZaUq2OBpfcRu/TtM3Sf.Qk5L6kG0TmHL.VyR551YJyO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022712', 'Test User 712', 'user_2022712@example.com', 2022, 'General', '$2b$12$klYiwokTK.stID/tVXBrau.qf/sAPe2DbOHY.C43B71tlJriMqXae') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022713', 'Test User 713', 'user_2022713@example.com', 2022, 'General', '$2b$12$3QIbvUY2YvjxEGBTFeMq8.C9LvBm1.qx1ix3YsSvLPK7CQfUBEBJy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022714', 'Test User 714', 'user_2022714@example.com', 2025, 'General', '$2b$12$UzmBa32xzo1DovBBJh/ceOc3PNGcr2UnLpc2I1zre7qxK5FDdsFou') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022715', 'Test User 715', 'user_2022715@example.com', 2022, 'General', '$2b$12$5rQMG3DMCN5IibM9Mp883.Ewp.VsPZPvemx61h9U6B.EgOoa/LCfO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022716', 'Test User 716', 'user_2022716@example.com', 2022, 'General', '$2b$12$yyLXdRLkz/y6oh4p4gmm9.taSqXL25ku.bTFWqv8WZVrlFppfd2Ai') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022717', 'Test User 717', 'user_2022717@example.com', 2022, 'General', '$2b$12$9FEA2AaJzKaJYFh.S9XhHuADHVFjmLX9P.LqzVJzfIoBWhf/PZGYq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022718', 'Test User 718', 'user_2022718@example.com', 2024, 'General', '$2b$12$XdMJWmVMGIdpKYwB05UCWuYSzXEexbWR2rXJC8R9u9A50vgdMZzW6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022719', 'Test User 719', 'user_2022719@example.com', 2025, 'General', '$2b$12$kCrIBkZSNYtMDZRE2UGFruwanvR.3RZbKWqa.0f51PRxsINz7cr7C') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022720', 'Test User 720', 'user_2022720@example.com', 2025, 'General', '$2b$12$7uAPdqGIusw1RANw29au0ut5omSctFVkvgE7WoRXSfFlcDYl67X7y') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022721', 'Test User 721', 'user_2022721@example.com', 2023, 'General', '$2b$12$YeEVUX4JiykvMVp0r0ynYeiKvDr/3YlW.w2nLrCbb1SRh9KH2sRay') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022722', 'Test User 722', 'user_2022722@example.com', 2023, 'General', '$2b$12$3tOrDJY7OIVNmmo56m5iOe6GeW1q4EV.X0tNgdJnNXS3i6HBn.6X2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022723', 'Test User 723', 'user_2022723@example.com', 2022, 'General', '$2b$12$p2apT8YOidg6ss8CZOt7Kekp7OJCqfNSzffeUxbOsElA/MxmfiAia') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022724', 'Test User 724', 'user_2022724@example.com', 2024, 'General', '$2b$12$MTIQGz.zT24T0rF30jh8FemANHCIfsW/d2JNgUXzSXLVvi7TdolLu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022725', 'Test User 725', 'user_2022725@example.com', 2022, 'General', '$2b$12$DhP4nO3HIHSbrqQmM3fB4.yFBRXCb2syhzXQW1aNMXjE.dMF3N7da') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022726', 'Test User 726', 'user_2022726@example.com', 2022, 'General', '$2b$12$22WAlSSlTnOCxAG4aw/8w.hg4FDWQA/fTF5rAkXmpWqybnjWrSq5m') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022727', 'Test User 727', 'user_2022727@example.com', 2023, 'General', '$2b$12$/X6uljdZa/snb0KoWEi4k.IGdGfqBo2YAe84jKmt4qNR3Yw4YpoIa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022728', 'Test User 728', 'user_2022728@example.com', 2025, 'General', '$2b$12$RoqfYAA8lsVKAOfRmBhNnuP.Myr.OAB5mp48bttPN6bOONsLs4LtG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022729', 'Test User 729', 'user_2022729@example.com', 2023, 'General', '$2b$12$II6kTUCT/1zGb3fT4uWRzOZpk8k7s9hLtRk1HJxEMwbPSb.w2RsZm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022730', 'Test User 730', 'user_2022730@example.com', 2024, 'General', '$2b$12$nAeRAvwn57ft4/2xo6y5tenltFuqT8rHi5roqJJE8804Q9LTBFzG.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022731', 'Test User 731', 'user_2022731@example.com', 2023, 'General', '$2b$12$ClvH.9xkwBZM/1.RLkwNYeoGTyEjihgJQCDCgyCNZIVTUfQxaFAwm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022732', 'Test User 732', 'user_2022732@example.com', 2023, 'General', '$2b$12$DvqKiPUR7rrArva7Veqwl.ah0XpT3dbmwGF3vLYfRUaUrtcZr/3te') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022733', 'Test User 733', 'user_2022733@example.com', 2025, 'General', '$2b$12$Uiqz1wYea2eQrqiZl4qIFOnWe1RvH5ZXxh1xq58OOkIiTGOM9.K22') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022734', 'Test User 734', 'user_2022734@example.com', 2024, 'General', '$2b$12$EaFPg3IKIjDNIv/NhPfT4u0tsIXeqMU3eTSx1NWNZ53uuRQ7RFR..') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022735', 'Test User 735', 'user_2022735@example.com', 2022, 'General', '$2b$12$DuJtt/vAEi8pcVlgjcFt1.aVx4VFnrpVCmJbuZw9pmz7AbLj9g./.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022736', 'Test User 736', 'user_2022736@example.com', 2022, 'General', '$2b$12$sF3gi5ReHb3Agd09Evlnt.pMuwcuKhAboNJLzBEp2.c/OHV1vmQUi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022737', 'Test User 737', 'user_2022737@example.com', 2024, 'General', '$2b$12$n17wYRi7DtcJxGFKqyqVXONQbZqrUugU/ShEzJ.yXHRftWFIjvTCq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022738', 'Test User 738', 'user_2022738@example.com', 2025, 'General', '$2b$12$bA0M6yVxdkj9KSWN9BQYneSRN1rtscLEL/90ybwNf.RMoI02NicSK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022739', 'Test User 739', 'user_2022739@example.com', 2024, 'General', '$2b$12$YoWn4ZwqDgQGpJIuKH/1CeEQGFkNb8fKWYUIPTVQXyElgLG73QEyq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022740', 'Test User 740', 'user_2022740@example.com', 2025, 'General', '$2b$12$D14ZAj.0p20ulBUXySsz4epab/9aMdeE8xABwTffez1HbQmdwXK.W') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022741', 'Test User 741', 'user_2022741@example.com', 2022, 'General', '$2b$12$yXJQDWEbXKv7Wt84vVPAoOac3ZTZhDcSKCs9LpcolwwOO9.sM2etO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022742', 'Test User 742', 'user_2022742@example.com', 2025, 'General', '$2b$12$.PcbH6AGw0kGl/X/CE/3du2sJ94sbV0rCZQPnrZPSjdNIfMUibIga') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022743', 'Test User 743', 'user_2022743@example.com', 2023, 'General', '$2b$12$ssBlRCnUqzdYTjtGnqo81e3iu0wM3YZsjfxrNyvxSx8aewWfY3CoW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022744', 'Test User 744', 'user_2022744@example.com', 2023, 'General', '$2b$12$9zqeUSIbhOMZ9UbpPr3I4erfzt4dkKA9cL8TdiyBDRtWwYul4yj3i') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022745', 'Test User 745', 'user_2022745@example.com', 2025, 'General', '$2b$12$cBCPOWEReRZFes/DwAv0NOs3jIDWvOKuiTA8mOPMicTJn/GyseyLy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022746', 'Test User 746', 'user_2022746@example.com', 2023, 'General', '$2b$12$XvjQhTDtt6.nNiAljl/cdeLpGslazLqzoELj4Sg7luSo290kV/mki') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022747', 'Test User 747', 'user_2022747@example.com', 2023, 'General', '$2b$12$R4HJZ6OUO8gLFncc2eZxCOV2NOlCnwGWkxNX/B5eV8.7IszSoDSvO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022748', 'Test User 748', 'user_2022748@example.com', 2022, 'General', '$2b$12$6YuIFJ5cbZNBOmPysYw6C.ibeMLHVol38WzrkxYCqvJrm4wFRLjde') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022749', 'Test User 749', 'user_2022749@example.com', 2023, 'General', '$2b$12$7sfBtQdOXDTq7StBEXjv9O8UafPsMYwPhprLrX3Qb6zf5roFT//ra') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022750', 'Test User 750', 'user_2022750@example.com', 2024, 'General', '$2b$12$ysfAZTX9IsC0cesH8zl4Wu038tSWvVpuizDlf.vXUQMGLbxbhTJZK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022751', 'Test User 751', 'user_2022751@example.com', 2024, 'General', '$2b$12$vdTo.1.mrplMkkrcU9EGlOeONbWDvEv3cx.W8j2f.MxhjoM5LeurW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022752', 'Test User 752', 'user_2022752@example.com', 2025, 'General', '$2b$12$pzLw0tpZrejoIyepyaap.O3IWlkICD.oc./qhtP5erU4eNGdMOKOK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022753', 'Test User 753', 'user_2022753@example.com', 2024, 'General', '$2b$12$RoGy2SMwr1hfp5r8DuI3ROtMSmxUOLPi7hdgAspJUzEy.xEJXa70G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022754', 'Test User 754', 'user_2022754@example.com', 2022, 'General', '$2b$12$qOAL9liAfXODYl4.ph47/u0kXRt4YYE874wd/Cxla7mB/3gJAy4Ce') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022755', 'Test User 755', 'user_2022755@example.com', 2022, 'General', '$2b$12$N3MJcYmrmiqKxHZ5EM0I3.0mgrjIb11zJcPWx5xGklqYCRm9v26fi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022756', 'Test User 756', 'user_2022756@example.com', 2023, 'General', '$2b$12$1ifFkJunkul0a9YAoBr12eYrTHBqo/39Wc4PRkWKcwa00j.6t.aIW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022757', 'Test User 757', 'user_2022757@example.com', 2025, 'General', '$2b$12$ZdH1fZgZWmx7hvOu7yMq2.AyVZTO7/dInvr/OiRFwHY4C09iCNiRu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022758', 'Test User 758', 'user_2022758@example.com', 2022, 'General', '$2b$12$emA.Yt692zIXtcGJdG5JPOPHXUPYWeoe1vUGQKNzz3kS.yr8u8h4m') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022759', 'Test User 759', 'user_2022759@example.com', 2024, 'General', '$2b$12$I1zhk2Jvyl6f.y8IL.WmnuKCaAzry64.U7K1L7Kxh801YNAl2oL9W') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022760', 'Test User 760', 'user_2022760@example.com', 2022, 'General', '$2b$12$lXRUgctyE24Qglq30cumh./00TxRWKCdPWhphGT3ut.FcEdbdb52W') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022761', 'Test User 761', 'user_2022761@example.com', 2024, 'General', '$2b$12$DA3N6Q/z6C7sn2S.Lg00iOpJ1B8s/gUnRSu262jVCJqpaXIAkgmyK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022762', 'Test User 762', 'user_2022762@example.com', 2025, 'General', '$2b$12$DwA3y2Po3s34UjYFoPiwjOvzNNb6LvCvMI7mfYBkmBDYBj7dpDN5i') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022763', 'Test User 763', 'user_2022763@example.com', 2022, 'General', '$2b$12$wb7A7bw8YgAA1sZVKnYGxu1nApHrERFhBheGTn9.yuElICTFFooW6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022764', 'Test User 764', 'user_2022764@example.com', 2022, 'General', '$2b$12$TtEVgJe6Etuf.wAoBCYGyuUFeLVQsrAGAYiUmN.NE/nIy7ElFATRi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022765', 'Test User 765', 'user_2022765@example.com', 2024, 'General', '$2b$12$Kxj.NhsFYx7rYlw7DDw1WeXfMR0Y.0116v5WnkW3k4dNxRqdbDE6y') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022766', 'Test User 766', 'user_2022766@example.com', 2023, 'General', '$2b$12$vHCmMH1rVy1bIocOsMsuROe9rERIXJqbAOcB1YbZK0n7taWh86mw2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022767', 'Test User 767', 'user_2022767@example.com', 2024, 'General', '$2b$12$7mD4pCpKXbSatyJQ4YusKeOZCkiPypdfjaOgNLue0fQg5M.DLWqdS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022768', 'Test User 768', 'user_2022768@example.com', 2024, 'General', '$2b$12$Ofi83Ct9jgci1QOagfM0u.J3ktMd2N0zvszqRo7nROiCegH3eYFLe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022769', 'Test User 769', 'user_2022769@example.com', 2025, 'General', '$2b$12$qF08//lFJEAcqNMn.De9je3pJ..pXrZTNWyeQpESLDNHV/wbqDfNO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022770', 'Test User 770', 'user_2022770@example.com', 2025, 'General', '$2b$12$eS/NfidDgwtZijowLk88deSJMlYGCLSaX20DFmpNTA4KDgcFUn31q') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022771', 'Test User 771', 'user_2022771@example.com', 2024, 'General', '$2b$12$7fMIkDQ0TUGXMGp6wUqRHetifX9O0wqfFD9mqX1PH68n3BP/EW10G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022772', 'Test User 772', 'user_2022772@example.com', 2024, 'General', '$2b$12$TyTBbOkgUeBFBKIbACvLjeW1GfPQn02A8BTVYVeC30H/.oFR3Yylq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022773', 'Test User 773', 'user_2022773@example.com', 2024, 'General', '$2b$12$BpV4kOIBEuXib8r43rpyDOwoXo5CUC70nfI7N4yFQbQKNwq2NclvC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022774', 'Test User 774', 'user_2022774@example.com', 2022, 'General', '$2b$12$7VW6OzGLt9dhCS6.1ilHf..oaLKiGI5z/1Lqkur0UO2Xtwe.TQXRC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022775', 'Test User 775', 'user_2022775@example.com', 2024, 'General', '$2b$12$AkHqV1e0SDqQ9QKFhY4FeeUJFXPmcNu2vzTN8gE22/zli6AXzCo1G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022776', 'Test User 776', 'user_2022776@example.com', 2022, 'General', '$2b$12$DjRLTbDIIA5sGvOA102FR.OxriSul61XpmNAaDMqriPiEpzAckyZK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022777', 'Test User 777', 'user_2022777@example.com', 2024, 'General', '$2b$12$gKHfp.cJMdvavee7RQ8Xfu3IyfhcTAKeIyekCuwHotrggn4g.Qe5u') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022778', 'Test User 778', 'user_2022778@example.com', 2025, 'General', '$2b$12$7.fdAOEFxOVwiGOklW5qKOTGERGkIKHFUyYuNt1OVMXjTUb2bAr2G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022779', 'Test User 779', 'user_2022779@example.com', 2022, 'General', '$2b$12$QlMsvd73DyCdVg./Sp5T8.r1ygjG0UEqrTZcehoB435T1r1xAZBWy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022780', 'Test User 780', 'user_2022780@example.com', 2023, 'General', '$2b$12$mlkjiJJwXfbTdvNw40jTrOeSAVfIww66kzm.eu/rrVWf0MmMwQEuS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022781', 'Test User 781', 'user_2022781@example.com', 2025, 'General', '$2b$12$evUDB/1haaRW77Wqn4kbWulBHaYA5uRg4cC5QgGelaU8xaAGPRG/K') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022782', 'Test User 782', 'user_2022782@example.com', 2023, 'General', '$2b$12$JIdziPDHY25T3P2qci1r8OBx6ExPKjDXwzn4/6ktNi6MULBvsRu6y') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022783', 'Test User 783', 'user_2022783@example.com', 2023, 'General', '$2b$12$AGbmEMSmRrrsoqQeM8eWKekvpx97ggwI9sHBHSE.daDsMvMUJx9CG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022784', 'Test User 784', 'user_2022784@example.com', 2024, 'General', '$2b$12$z8MYCJEuhg0TYCLhvYPANOAhQB4yz4f5INdW0vbcZ68h2ciNXBApi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022785', 'Test User 785', 'user_2022785@example.com', 2024, 'General', '$2b$12$N.D1b.4wIZZZGuiiX8qrM.9ZWY.zUO.p/85aivMuBtvuwJ.BYw1C.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022786', 'Test User 786', 'user_2022786@example.com', 2023, 'General', '$2b$12$BtQ43zop2kpL6eUkJwGZE.fGDa8ADrX1WE90smJclbV9GyMFXt7EO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022787', 'Test User 787', 'user_2022787@example.com', 2023, 'General', '$2b$12$tjhsD2Aajsrs9RVTANuxTOpLMhPjtJLZJHT0jd7qfc71utQV1l/LC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022788', 'Test User 788', 'user_2022788@example.com', 2025, 'General', '$2b$12$ARHxjGwNJ/C3zUucOyxPBeKjswnpxedRf82W12mAc2xpcNQrXxtNK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022789', 'Test User 789', 'user_2022789@example.com', 2022, 'General', '$2b$12$nXktP5CQn3F5UO.y01/p9OHiZTzD5qIbM2Hn2B6hO4Qub6YndooKu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022790', 'Test User 790', 'user_2022790@example.com', 2025, 'General', '$2b$12$Apd23DXHeKiUzWFPPPwhPuC9d/f/YV6/Ub4rLGolNqcxt7ZX8vOX2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022791', 'Test User 791', 'user_2022791@example.com', 2024, 'General', '$2b$12$cbnqIu2KoZxmRYoH/Fg4u.u99W96fVHVLGcFzPbI3oGcTPlOLISlG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022792', 'Test User 792', 'user_2022792@example.com', 2023, 'General', '$2b$12$sx7r5gMvN0KJXmtqzH8b7OF41fYQxsQ0.WjMf8wrCMtRr3LZaViz6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022793', 'Test User 793', 'user_2022793@example.com', 2024, 'General', '$2b$12$OhhnAxYRu1pYRDm7dFPAT.BkFAJTQjtnQbnwaOjdQ.ezA.iWeIILG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022794', 'Test User 794', 'user_2022794@example.com', 2022, 'General', '$2b$12$GqZbGhrbj5KVbubccvcgiurIHS2rqdbD.Uggibk0PKnVK02Kicz6u') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022795', 'Test User 795', 'user_2022795@example.com', 2022, 'General', '$2b$12$KKUH9Ag/ZVc7nyVNQE4bK.gcIYKvfn.Rru79i3Rgnrlr92yPhiVIC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022796', 'Test User 796', 'user_2022796@example.com', 2023, 'General', '$2b$12$p5i2lLQ9peW956DKRUaRi.7o521LZyhRkEuD6FAwxzN3cLkxSvbbq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022797', 'Test User 797', 'user_2022797@example.com', 2022, 'General', '$2b$12$IVJm08zrPhZDVM6tGJUvye60rbMNE6Z.nVKmUF6M.mgX43YfAzrmS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022798', 'Test User 798', 'user_2022798@example.com', 2023, 'General', '$2b$12$75xjuIJuYetJ0sLBgfreX.GswHJIwXmWneRFvBlj9inEwPuhTa81e') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022799', 'Test User 799', 'user_2022799@example.com', 2024, 'General', '$2b$12$DzdaLGktMMOAd9Rd0r1nz.d8/4LJfi8R30ADG8K9uIKsaRKeLlqL.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022800', 'Test User 800', 'user_2022800@example.com', 2025, 'General', '$2b$12$wuUVFjk9rzuhh5pQArwEae4f8McjZo6mZ0Rud9eWV2W9tdzavv9lC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022801', 'Test User 801', 'user_2022801@example.com', 2025, 'General', '$2b$12$fidKKYm/.GLKRZMloJJS2O4TQ8HL4V8ydHABGoifJjlopSvLu4b7y') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022802', 'Test User 802', 'user_2022802@example.com', 2022, 'General', '$2b$12$p2he74re09ew2bT0dITHoeGCs7xTZyhDbJp6dWaDpcD2/jLt1TYcS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022803', 'Test User 803', 'user_2022803@example.com', 2025, 'General', '$2b$12$R36gjgLQt3JyXGv6ObIiZORY1jfPOQJIZXR/X0AwdHlKkz3W4gTVi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022804', 'Test User 804', 'user_2022804@example.com', 2024, 'General', '$2b$12$mLQMcHp626r3hdSCKTLXVOEBM10qEKIPM1YRuyyok1HiVrCb3xHMO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022805', 'Test User 805', 'user_2022805@example.com', 2022, 'General', '$2b$12$muoZ6oPewSob6EClpGEhtufuSpz0XM6.Tqxnh0Y3sLeSUfH0NNhIG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022806', 'Test User 806', 'user_2022806@example.com', 2022, 'General', '$2b$12$HxeAc0U.L5Mldx2gGWC4FuS.KFZspVojCffyYfC0niA8J0TGc32be') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022807', 'Test User 807', 'user_2022807@example.com', 2023, 'General', '$2b$12$cUm37IQHqEP7C0HGVPiMguw9KbMf/b2dBKM61gUWmrP.eQgPX/sa.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022808', 'Test User 808', 'user_2022808@example.com', 2022, 'General', '$2b$12$E9qbQkm4ZWpBvXcPwWBJ..bbxHle5E0gVChe.fQ9Xv56JKpWuQiNi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022809', 'Test User 809', 'user_2022809@example.com', 2023, 'General', '$2b$12$Gi.0yrU1yiF14qd1BEMPXenPEZkUObq51XuSS4u93pz/cRKpFWVqi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022810', 'Test User 810', 'user_2022810@example.com', 2022, 'General', '$2b$12$0BEC28KwBCdR1tLBNIYqZehYyKD.TGD5t6A7.znG.n2/AN5S708fC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022811', 'Test User 811', 'user_2022811@example.com', 2022, 'General', '$2b$12$J1mLOR.qj9TLsQN9G7y94.CZvgR7OWDKmIBHSmFdw9MXdwXsNqdWi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022812', 'Test User 812', 'user_2022812@example.com', 2023, 'General', '$2b$12$yhBQisrpie3Y29ptBjBBwubJ8UttCxZ3354p1MeJlWf263c5h6L9W') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022813', 'Test User 813', 'user_2022813@example.com', 2022, 'General', '$2b$12$CtUpDmUmeP7kAbkcXKLFMeDluu/2zWutw3O/QHuw/ic2RlOMc5vdu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022814', 'Test User 814', 'user_2022814@example.com', 2025, 'General', '$2b$12$MnuK6hiOHPpT40VajSxI5ud..0zAOUWSXi0zPU.NSR84g.eW8q2o.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022815', 'Test User 815', 'user_2022815@example.com', 2023, 'General', '$2b$12$P.eZTtvDKjdUA0tDhHbxg.rMZDXmkrEkvHkevxS3Q6q48CsxFURf2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022816', 'Test User 816', 'user_2022816@example.com', 2023, 'General', '$2b$12$//G9KcOO9kFcyJh/QS6ICuheXfPLD8XLNHFHs5OivullY.Ed6qp/m') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022817', 'Test User 817', 'user_2022817@example.com', 2024, 'General', '$2b$12$eMxEuds6DP.SggaaPo/EHeX4hqQ/9ckpMF.sYfWuk30R8PqQMRZqi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022818', 'Test User 818', 'user_2022818@example.com', 2022, 'General', '$2b$12$F5bLOwuO8wazY/kIufRyduJijCVyn/eUOv/F2755KrFQJEWNJ1XQq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022819', 'Test User 819', 'user_2022819@example.com', 2024, 'General', '$2b$12$v0si97YEflWpRfvtRepQT.n8mDgDavrqYxnwInc4NzIo/ewU02PY2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022820', 'Test User 820', 'user_2022820@example.com', 2023, 'General', '$2b$12$rE7oNgKC2JCBknRAAGqUCe3Ikq5A6l3iskBJP8u6aGKm.bm7DR/22') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022821', 'Test User 821', 'user_2022821@example.com', 2024, 'General', '$2b$12$0BFnUzae9Sc5R9lSiFQb3eGckHOKBCScPGcf8iX4pwNl5HKdTxfze') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022822', 'Test User 822', 'user_2022822@example.com', 2024, 'General', '$2b$12$FYMC8xevYt85UpDz7uWk0e3JclitCBA1Zxsls7Figzmr90ns7Xv0u') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022823', 'Test User 823', 'user_2022823@example.com', 2025, 'General', '$2b$12$kgjUmwJmZQpsWuKMKBF8EuSa0I648RmHPp15Fikta1Xk975NGYB7i') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022824', 'Test User 824', 'user_2022824@example.com', 2024, 'General', '$2b$12$zhWcO9dV/YP7xMZJDbSz3OG/TDT67OPt/aMzeiFD6bvXv8Yo3CqIS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022825', 'Test User 825', 'user_2022825@example.com', 2025, 'General', '$2b$12$bPQD77dXxU0VkWuOsRUmNegLkq9nThMOiJpc2nENCW1xItr1lrwKS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022826', 'Test User 826', 'user_2022826@example.com', 2024, 'General', '$2b$12$rkXaIqzXoRXiJsiJasouBO5xUsbEiQAtP9/.OQ4Q0HXSJMqRlIY7.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022827', 'Test User 827', 'user_2022827@example.com', 2023, 'General', '$2b$12$NcMX/bCfXfkoQeluFN4z0.Qg0R4cLX0vR7E6KH9FmwbM9aTn9SyP2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022828', 'Test User 828', 'user_2022828@example.com', 2025, 'General', '$2b$12$GkFWbWxEdYzdY3017U1Ooe1fzagvideDmKrjfTDtUhBegiyiVRBuW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022829', 'Test User 829', 'user_2022829@example.com', 2024, 'General', '$2b$12$umKkSbfKb6fzVCfBzz5iVeQnJVTut5uHb59TXEzA1oC0jEOIVRN/a') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022830', 'Test User 830', 'user_2022830@example.com', 2024, 'General', '$2b$12$avjO40iisns2cpN7k.WwUuHa1fkw7y4jANB3bhKZJ0mqfc7tZkwja') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022831', 'Test User 831', 'user_2022831@example.com', 2022, 'General', '$2b$12$80h5zMS4S1cxkVw.Olm.wecFx6KzGCQxIVWaOnd7Gnx6kv95EsaF6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022832', 'Test User 832', 'user_2022832@example.com', 2023, 'General', '$2b$12$0Ls1sgDkX1zg24xJI/HXIetMEqyW0kq.EqJowqk1l5Y5kHT23QBpG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022833', 'Test User 833', 'user_2022833@example.com', 2022, 'General', '$2b$12$hLFz.xUaqdQPMNxl5h8at.LH67jgkEbSG8BW9jUB4uD3IrzdPvpRa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022834', 'Test User 834', 'user_2022834@example.com', 2025, 'General', '$2b$12$nqGhqgNiOWZPr2OToP8icOcN4VrpBMqXzfHdzVv0m1EgTOvHmx8zS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022835', 'Test User 835', 'user_2022835@example.com', 2025, 'General', '$2b$12$N1z1nOU4t2a5C44Vlt4DlOVBrF.BrPk8jI2U0z81hFWN6mFHIHmsi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022836', 'Test User 836', 'user_2022836@example.com', 2024, 'General', '$2b$12$horuMk67C3jDxi7C57gAA.3Qkl6MskvAcDigFrX5PNCdksbaj6Xza') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022837', 'Test User 837', 'user_2022837@example.com', 2024, 'General', '$2b$12$IfK0YTwhCzq1CySRIto6jObIAphgB.dgUgr3N9GtA7Rq7PPZZYHVi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022838', 'Test User 838', 'user_2022838@example.com', 2022, 'General', '$2b$12$owELzlGXUDZCo5GNSz9AFO4sO2BFpQwHt.s7UUWeTfml53sdKilqy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022839', 'Test User 839', 'user_2022839@example.com', 2023, 'General', '$2b$12$omA2XvLHthfcVMYSbpiII.my1ee5z5dRam4p1HB.nSrL4YJ770Xy2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022840', 'Test User 840', 'user_2022840@example.com', 2024, 'General', '$2b$12$7bSXQYwqX9yVMYwssTz5h.FhazOVHbiRQAuxOBp8pDCXEEueCdBVS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022841', 'Test User 841', 'user_2022841@example.com', 2023, 'General', '$2b$12$a3KV8f0U9XRupVeaLAS/O.EIgeQwXfKoAf72R1usrBWA5WGDt3MA6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022842', 'Test User 842', 'user_2022842@example.com', 2022, 'General', '$2b$12$htSr34DK7znbSTXQyJVopea6IuSoY9vja/b3VB3oaiRTfxTc4RoMS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022843', 'Test User 843', 'user_2022843@example.com', 2024, 'General', '$2b$12$0Gltft8wVU1QE5tvpeMes.u9pPxm33WWh73IByKgEyOxC7.DA7S8.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022844', 'Test User 844', 'user_2022844@example.com', 2023, 'General', '$2b$12$lrgTHrA0E3O1rd0uDziK4.CV0HKTAjfCvw.tyL164YO6uNpyVq1ju') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022845', 'Test User 845', 'user_2022845@example.com', 2022, 'General', '$2b$12$zJbZ.3JYyRKmRM.Gl7uXzuLCTNE6amezzJisVHIpCDXBpjgty7yM6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022846', 'Test User 846', 'user_2022846@example.com', 2025, 'General', '$2b$12$x4mVhjpFnXaVAlJJ38Cbgez91Oa2sEIHg0L9OMwOrkZqIqrybeoBu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022847', 'Test User 847', 'user_2022847@example.com', 2024, 'General', '$2b$12$WZ0lxnFgGORBleEWeQwDw.hNFcMwQtgQvWvfZgiJBXcpn/51HIDh.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022848', 'Test User 848', 'user_2022848@example.com', 2023, 'General', '$2b$12$.aHpix7ebvh3Hl9iAz6jVeZKdh8zKPYbFtE2zSzgUxtV2JfYR3sSm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022849', 'Test User 849', 'user_2022849@example.com', 2024, 'General', '$2b$12$eG35CP5P5LS35J.tVGl5aueFcI0FS8WQOdrWN6SDZ7yatBrRUz08C') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022850', 'Test User 850', 'user_2022850@example.com', 2024, 'General', '$2b$12$lCiWZhaj82raEQc4GeFOpusv6MOTAAyWl0IqSkW0X4YLkk0yFknLy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022851', 'Test User 851', 'user_2022851@example.com', 2025, 'General', '$2b$12$3aE2wngRqi3YFxY1v.e0KOu9hV0BFyG7gz52oYi.ArNn8XXH68DsG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022852', 'Test User 852', 'user_2022852@example.com', 2022, 'General', '$2b$12$D9lj7/qZ4VNUGffLLF3lYO6bNEqwVcrpPk3SqL/9cVo8FAjBX6zYe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022853', 'Test User 853', 'user_2022853@example.com', 2025, 'General', '$2b$12$N1vkOm3s1.8ugwhv6Lyk8ePiGnf/nQBvYoWa0P97c4a2YBIORgG1u') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022854', 'Test User 854', 'user_2022854@example.com', 2024, 'General', '$2b$12$vdfvB3oTQm32fgFDqhdS3.JMtZro5uxInm3xIJppWI5F/d2xuqCNm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022855', 'Test User 855', 'user_2022855@example.com', 2023, 'General', '$2b$12$NJVHPTQTHDnABFaQkhGrrev.SDbE8pjYC1C5z/MaonP/5SS9LBaGu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022856', 'Test User 856', 'user_2022856@example.com', 2023, 'General', '$2b$12$rj58eBcqnafTD2xQN/XkNecWzhbZmDdngJoUa8/gDAYnjJvCuC7ay') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022857', 'Test User 857', 'user_2022857@example.com', 2025, 'General', '$2b$12$dz6V8wlhNB5HbxCApxrg/uiGzbq6wXv.JNXFrRwc87QFgn0i1DPam') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022858', 'Test User 858', 'user_2022858@example.com', 2025, 'General', '$2b$12$J1AjvqLWx56VQfQYRoWEduWufKGYNu6MOJGjjPBCBGN/j.UDiiPOa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022859', 'Test User 859', 'user_2022859@example.com', 2024, 'General', '$2b$12$mo6y/rkBS.HNdTHxIOHuXeWlmZcvzAJt/NPkOCMrraPPJ4Ti2wwhW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022860', 'Test User 860', 'user_2022860@example.com', 2023, 'General', '$2b$12$X32lqgEDOm4p9YBTbiJb0eJNGFVrSlDoZ43Jb8aAg48IRMDWSaU1.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022861', 'Test User 861', 'user_2022861@example.com', 2022, 'General', '$2b$12$p3urgWnfI3.HmyRpEtDfX.E7OqiXEL2YeGRCWin77qd1IRC/fUafe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022862', 'Test User 862', 'user_2022862@example.com', 2024, 'General', '$2b$12$TIfdPruoQIl4duubjnhBGeQ5erTGOFfq30RuHoR3YPkM74L4SU62e') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022863', 'Test User 863', 'user_2022863@example.com', 2023, 'General', '$2b$12$3j9058nCw.faIwGEn5k5Xuo6Lvl3Qd5el07OjHTzHWw4bqAltYVdO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022864', 'Test User 864', 'user_2022864@example.com', 2025, 'General', '$2b$12$LEXqgi.Shdy8qp1mBYeJveWuFmIBW4KHeBtNcQJOe0tyExuB0vc42') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022865', 'Test User 865', 'user_2022865@example.com', 2024, 'General', '$2b$12$.RcFdnrJhXTBrSYg0DiNJOWISwxXcb0YW6.m/cKcsuOViUUsIfdYG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022866', 'Test User 866', 'user_2022866@example.com', 2025, 'General', '$2b$12$I5WJauJt8cqkl6PkYLMMJuIxZNMXXcJDETyC31IGKqUqVzA6fWU/C') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022867', 'Test User 867', 'user_2022867@example.com', 2025, 'General', '$2b$12$iWp2gDmhmhGlsiWeAOqTUuSBCstuDC92O9gjG0zlawnPRm5u2iVDa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022868', 'Test User 868', 'user_2022868@example.com', 2022, 'General', '$2b$12$2n.MPoRe.iX/BlGQRtfrMuDcthNOto1BnexnL.8lUNYivsz9eqmLq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022869', 'Test User 869', 'user_2022869@example.com', 2024, 'General', '$2b$12$wbOq7VFIM2gFnF.2ljJECuLQjZhj36hBGlvkEei4pu12.KUiKdYPa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022870', 'Test User 870', 'user_2022870@example.com', 2024, 'General', '$2b$12$x.KOOAwQsqkdmiGkx3dz.etnovPAzLxPePvLBL98zh6GxkCG0OcL6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022871', 'Test User 871', 'user_2022871@example.com', 2025, 'General', '$2b$12$lp8CqmTpBCP6gr6h0stPgOjKopSb8/NkmrE/NKrSpKFH28eYVH6tu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022872', 'Test User 872', 'user_2022872@example.com', 2024, 'General', '$2b$12$77wUuCGDZIrEhN3YNZAHUOEM5OgFBcwsLJRMcaSY03.L9NROXmmn2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022873', 'Test User 873', 'user_2022873@example.com', 2022, 'General', '$2b$12$KsjAdCBaOcAd/GlK2JjrM.jevepd0P6XGe.c28uyZmTQjBLd8Kn9y') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022874', 'Test User 874', 'user_2022874@example.com', 2025, 'General', '$2b$12$zugsdoI/U7EWZiMkAgDbLukwhx/kxysAg6fcEF4ZS2HCi8giDRGfq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022875', 'Test User 875', 'user_2022875@example.com', 2023, 'General', '$2b$12$UnXFEnO8ffhNN5Czmwk4N.G.d52ZDo2ByW2UaEdwYvfB7asO9bru.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022876', 'Test User 876', 'user_2022876@example.com', 2022, 'General', '$2b$12$OwexRi7HsUVCpo7jk4ORJeD3ADzwSotIQA18j/3aPYlOBhIdjhYXi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022877', 'Test User 877', 'user_2022877@example.com', 2022, 'General', '$2b$12$ZJ1Euqv/hMqvXQXEBkuJXuaFGqEyhfNXg0jwROyOYau4rCvfVapOS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022878', 'Test User 878', 'user_2022878@example.com', 2025, 'General', '$2b$12$4lIU.hUYnlczEDM172.oVu4KTFTY.EysZHYcLyG0crrj9YtWcc9hC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022879', 'Test User 879', 'user_2022879@example.com', 2024, 'General', '$2b$12$g4VfFnxV8tg2HtnhBa7DQuXC9/Wb4UIGuAjKEZt5B6o1eQtPr/Ywa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022880', 'Test User 880', 'user_2022880@example.com', 2024, 'General', '$2b$12$KtvLBpnYBmrWaBBy4Yl.P.bqAQ6/VzaoJsLWRqhZ/5i0XxkwTm5iq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022881', 'Test User 881', 'user_2022881@example.com', 2024, 'General', '$2b$12$/CS/CE9MkTPmES2naoVLoemQKchcnRJ2tTVRWHcLduQmhCEQyCHMG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022882', 'Test User 882', 'user_2022882@example.com', 2022, 'General', '$2b$12$MW8QU5Quo9Rn4JqCaA3xh.gf0M9GPiNRAJSGyOdHWfGzep7dauSFi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022883', 'Test User 883', 'user_2022883@example.com', 2022, 'General', '$2b$12$1PdTVJDoun05Z/AkhywkjOZH38jLTsVOUrU5fmzerLzTgm5apOAp6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022884', 'Test User 884', 'user_2022884@example.com', 2022, 'General', '$2b$12$MbsV3/nMIRYaRo5ohtTPTO6qlVAV/WG1v0Phd.E3rAWOeWvXQfCVe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022885', 'Test User 885', 'user_2022885@example.com', 2022, 'General', '$2b$12$VvKewORstV2sIId7exxQweGVOcZktoM9oRqQrP1e165jUuwpsuPN2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022886', 'Test User 886', 'user_2022886@example.com', 2025, 'General', '$2b$12$T2JTxHGryZettYVaMTFL8eTsgAAK/vYaAlS3Z18co.UYD2g.f0qm.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022887', 'Test User 887', 'user_2022887@example.com', 2023, 'General', '$2b$12$XhDt9hxUjfZEzAVIYaz9U.BGnBllgBy26LFP0G6rQgbtemtiksHUa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022888', 'Test User 888', 'user_2022888@example.com', 2024, 'General', '$2b$12$dDzME6Fng2KnQLCv0uV/k.PT0bncmiVB7g1eEtYzrpb.HRBd.X/F.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022889', 'Test User 889', 'user_2022889@example.com', 2025, 'General', '$2b$12$2iRocw2Kqv6ksRC5zAxmK.3eWTxcpyUstLjgng/ONgiOY7njQROky') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022890', 'Test User 890', 'user_2022890@example.com', 2022, 'General', '$2b$12$swp5vAydyJqAJ36J.ZbK1.zLof7hqY.IF7TkZyVN1laRETMCEHxb6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022891', 'Test User 891', 'user_2022891@example.com', 2022, 'General', '$2b$12$5vjktF5cPb.C.1eRu5n1Sete7bqgMToT7OtflOFSOmSGRUAwOM5M.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022892', 'Test User 892', 'user_2022892@example.com', 2022, 'General', '$2b$12$dPhTrqu85W7udkBEv8gt7OO9djLWQIiZGyjg2lqBrrLOcjz2Mcaja') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022893', 'Test User 893', 'user_2022893@example.com', 2025, 'General', '$2b$12$Jh0O2gOU6IMjDliAxWDWsu8nBYVEKzkuX2ho8IZIeTEhEN.vXf.AG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022894', 'Test User 894', 'user_2022894@example.com', 2023, 'General', '$2b$12$ZORkMVtdRHSqg3HKxKwz4.tv4qPCTnYjUOQbM2.kLq1Bbvb/TcLOC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022895', 'Test User 895', 'user_2022895@example.com', 2025, 'General', '$2b$12$aFKUkdP.j35t6Nyz7/BfHOcpMw9ONldxck6kJ4F6r8uwwVTqaNj/u') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022896', 'Test User 896', 'user_2022896@example.com', 2022, 'General', '$2b$12$8t.Dnvt.vF16gFuZ2nJSs.AluY91.riGqww4RhGUzuoS6hxOI79zS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022897', 'Test User 897', 'user_2022897@example.com', 2025, 'General', '$2b$12$8bL2ZszdR3D8Ar2sUpyEJ.uQwgYgE9ij3E8033CDWAd4HkfWoJK8G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022898', 'Test User 898', 'user_2022898@example.com', 2023, 'General', '$2b$12$iLHYy8tRn0iKsaZhac1aquQ4Vmux.cSm2N.kFjE7QFFHry/0LASw2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022899', 'Test User 899', 'user_2022899@example.com', 2023, 'General', '$2b$12$mfx151NbWv.irp7KjZGo1eWnULwO9qB632um42vl4eJpv4Dvipcdi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022900', 'Test User 900', 'user_2022900@example.com', 2024, 'General', '$2b$12$6mf9YmYpwKqbvuDxTn.L7O2vDvJDXoZzgZlYi6x6Za4nqZ4AXONN6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022901', 'Test User 901', 'user_2022901@example.com', 2022, 'General', '$2b$12$yUzOtxXrN1zfzGuu4NLX9uZqrUGKE9LGXka.vFX3KLfpvvInfZwAK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022902', 'Test User 902', 'user_2022902@example.com', 2025, 'General', '$2b$12$.mxtoYX9LQE3wtvQJUbMEugvr784RoAMvL3xbroJDQ6SxzEm2l5Vq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022903', 'Test User 903', 'user_2022903@example.com', 2024, 'General', '$2b$12$VAoHC5ky6SmWoC2yp6S82uWufgA6kuNU7djGoI3/TSmBVsjWjiVUi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022904', 'Test User 904', 'user_2022904@example.com', 2024, 'General', '$2b$12$OPe97D8EDNumocwsDlb4H.4XhvoHwGq02IHuYjUA8MqdRjYJwQgxS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022905', 'Test User 905', 'user_2022905@example.com', 2024, 'General', '$2b$12$vTZUSNjoID/o0RyLtyY6auB4scPxNkOu1JariZp0SpeOqt7nL/eQC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022906', 'Test User 906', 'user_2022906@example.com', 2023, 'General', '$2b$12$4nJpfKKF91jsaZpDBpc1bu9lEepB75qfUttzWBX9ANHOx9t8PP1aO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022907', 'Test User 907', 'user_2022907@example.com', 2024, 'General', '$2b$12$kf3SfHLbzAzqlEiOMcYnXuMFSnqMsTSSGe0Q93.Ev2EK4FqAJ3Ssu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022908', 'Test User 908', 'user_2022908@example.com', 2022, 'General', '$2b$12$HwyVqYsBDxf/BprYNAZO8eLhSmPGovaRAfUO0rVrCwJnv1UHR7jRe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022909', 'Test User 909', 'user_2022909@example.com', 2025, 'General', '$2b$12$Blaox4HyC.ZgFxd4Q7Fcy.8lk4qzPG.7WW2Thzt3waf4pZqCr2CQ6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022910', 'Test User 910', 'user_2022910@example.com', 2022, 'General', '$2b$12$DMzl5UTosTwNfCzHx0Qk6em1jOulLRUSNQsdQsu0Gth20/n92yQuS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022911', 'Test User 911', 'user_2022911@example.com', 2022, 'General', '$2b$12$l/gYlz3i7VNGFaGkLsvVdudut/TvLDVCIQQQM01HpHC5UzunBL9Wu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022912', 'Test User 912', 'user_2022912@example.com', 2023, 'General', '$2b$12$/8ueO.h.M/Nh9AMqk8wg3OpcQPZjvtHKK7xKwAZP9gReG2LVmdiau') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022913', 'Test User 913', 'user_2022913@example.com', 2022, 'General', '$2b$12$8nE/ukPNMAWJ9yJyrDosDedyUXvyRdV0bM9PLnjqZl5/uegPjZ2s.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022914', 'Test User 914', 'user_2022914@example.com', 2022, 'General', '$2b$12$d4w2NQkBWqueDVG0SgWX1eAcU2r0nOSGs13lgwo5tSCQO9VspaU/G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022915', 'Test User 915', 'user_2022915@example.com', 2024, 'General', '$2b$12$EqH/AzpryfD4xN6NOaCE6.nKKQrtwzkMSru1BFtMvLYf94rfUHN2q') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022916', 'Test User 916', 'user_2022916@example.com', 2024, 'General', '$2b$12$dmB.Z3/VLpZYdLrr640GjO4H8h7OYTUnYQ9YtVqm2/DXEO0v.ixwS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022917', 'Test User 917', 'user_2022917@example.com', 2024, 'General', '$2b$12$xamsNo7oCxE8NXiqi3sUU.RyKxZfLv43lCJ625zebPpVX/aWo61pS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022918', 'Test User 918', 'user_2022918@example.com', 2024, 'General', '$2b$12$PWfwU4jNv1Xu0RFXi3GxXuMmlMbjJ/DWQRF5s0selBzHBK6nBNUdC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022919', 'Test User 919', 'user_2022919@example.com', 2024, 'General', '$2b$12$ill5JtcCRPNJ0d9A1GG4vO4.ezZudx9vatdeKFkQO5F1xbo9.PHHy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022920', 'Test User 920', 'user_2022920@example.com', 2022, 'General', '$2b$12$UXhWkj0sv2uKX7jkAoS3WeAvttLXMotZWwGcbgGtncxZeZ2nmGLjq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022921', 'Test User 921', 'user_2022921@example.com', 2023, 'General', '$2b$12$nyI7/04i2d1TbaRR2hBh7ub9eGKqQh3N54iZ7sgAMPS6f3ujhqD36') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022922', 'Test User 922', 'user_2022922@example.com', 2023, 'General', '$2b$12$1oa2oMwLyFrHwgKrFssqLejHofUZBpq8HqEMgwlFzhQ96eJmGVFfy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022923', 'Test User 923', 'user_2022923@example.com', 2023, 'General', '$2b$12$dJdQTbI.u/NHauofIRMCge6KkszyFX.I0QVok8782mhmEnLCqnoGi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022924', 'Test User 924', 'user_2022924@example.com', 2023, 'General', '$2b$12$HbC3jVyH5dcxXJZdN8/pdehtf2i/jLN.Vy/OC77z6ZhT2MMQI4FJC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022925', 'Test User 925', 'user_2022925@example.com', 2024, 'General', '$2b$12$hzB8uBJYG/kAmmhPrkhSn.Z1xUEPhisWsjpqWiU5ybAwS2oWThfWC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022926', 'Test User 926', 'user_2022926@example.com', 2024, 'General', '$2b$12$32azuEWjindtdqxONbgeP.v2JekfIuakdSQHWGP8Os27nQQHG6FAe') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022927', 'Test User 927', 'user_2022927@example.com', 2022, 'General', '$2b$12$dnXdr3IqlExxc7dR60OIiOskGsYGrIcnQByrsHBaYyQQC18KSvyRa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022928', 'Test User 928', 'user_2022928@example.com', 2024, 'General', '$2b$12$2leXdlVBwaAdEXr3NYQYIuSG5mFG7SNk4WeIlBH1ehWK/OCweSiwi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022929', 'Test User 929', 'user_2022929@example.com', 2025, 'General', '$2b$12$c2VwSUIoEuCzaQkvSR4CQuGtupQoi5Z9PKAzt/X.0znpP.zlr/.Q2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022930', 'Test User 930', 'user_2022930@example.com', 2022, 'General', '$2b$12$t56u1Shn9etmcl35hlksBOYor0dph4Q/qnFhVD5oS7V.3UIaA4MsC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022931', 'Test User 931', 'user_2022931@example.com', 2025, 'General', '$2b$12$dWEUKDhsnOE.z0UI9oxwMe02ncWO42N.KF2Ea.P/zgzP2hLRbpuii') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022932', 'Test User 932', 'user_2022932@example.com', 2022, 'General', '$2b$12$rVVsde8a3FHT/MF0EcKC0.kzFiQOUF/MYSRto2o2UKYGJwIM8hCSC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022933', 'Test User 933', 'user_2022933@example.com', 2025, 'General', '$2b$12$crhjT/1wZWHldcWB2SBX2OegcPPzQMh.FWo07COrRv8lbiQXWu/bi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022934', 'Test User 934', 'user_2022934@example.com', 2023, 'General', '$2b$12$lmeLHI17K3Hda9YGN2n.zuhtHbF5Cz6f9V3iSjBN.hDSMmZ8L47Iq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022935', 'Test User 935', 'user_2022935@example.com', 2025, 'General', '$2b$12$xE8O/2S0b8/fYxGUh0glROTXM4M/8nVKezv816vsOwc1aSsTWunE.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022936', 'Test User 936', 'user_2022936@example.com', 2025, 'General', '$2b$12$YijfD9xfk1uPmMyqvnWTK.OgYwuFs/wHM1ed0d1.Jv.MCrm9C1gMu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022937', 'Test User 937', 'user_2022937@example.com', 2024, 'General', '$2b$12$fly9aaKYLjx/Bs26LtbuBuYMB2iTF2zS7btAoRwKLPZAp1H/s9.Na') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022938', 'Test User 938', 'user_2022938@example.com', 2022, 'General', '$2b$12$Bf6Sl0BoEgrajtQZbCjvju0887SRdPM6QWFZB8wzFMAn1.bq4YjW2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022939', 'Test User 939', 'user_2022939@example.com', 2025, 'General', '$2b$12$YOyPks6Et.zcFVa7.BYlD.ENBLwJlsHojzFQR5MiCYZP4cadjEmBW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022940', 'Test User 940', 'user_2022940@example.com', 2023, 'General', '$2b$12$JP2GakUUsjxDIEfnzcgbue9.daHM4zJroMFwZ1yhUUsVc4Fjcif2i') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022941', 'Test User 941', 'user_2022941@example.com', 2023, 'General', '$2b$12$gigGcYkmYclCtWMyXmQaCuseyG8tzY.ZlSaUfEny5d4E/uiKGIk8O') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022942', 'Test User 942', 'user_2022942@example.com', 2024, 'General', '$2b$12$LCocQrScH6xwEq3vXqTyT.0x5aW81mghjRsn.st675P1lBy/DwuPa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022943', 'Test User 943', 'user_2022943@example.com', 2024, 'General', '$2b$12$LgEwLm58KNDcakNzK1GdJuNUQO2JIE82A5fQFrVm54o6NyJzPzVUa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022944', 'Test User 944', 'user_2022944@example.com', 2024, 'General', '$2b$12$xtG1Cef7nVfEk7hFQM.DYe78SPt.yfgXOE3ksWwUDP.5zrsSdYyk.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022945', 'Test User 945', 'user_2022945@example.com', 2025, 'General', '$2b$12$HkiyVFFfJFOTLN.3S8NeUuxeIRKwp/tfJ3dIcpCOJ3UqBTuU0QbdO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022946', 'Test User 946', 'user_2022946@example.com', 2023, 'General', '$2b$12$vIQ.mU46oMEzSauCxVMOZOXbUGBWh9IjpFhBykMajMbDpMt07LcRK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022947', 'Test User 947', 'user_2022947@example.com', 2022, 'General', '$2b$12$cWxGVfYEQ9p8A92C3mAoJOWXTc7JywvbmsLqSYmDfObKj9IlwGM5i') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022948', 'Test User 948', 'user_2022948@example.com', 2025, 'General', '$2b$12$autt7hTPGDGAAX24hrtq2ezJMDl7/nysPKyHbnQ7DxXvkZ9UGdJQ2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022949', 'Test User 949', 'user_2022949@example.com', 2022, 'General', '$2b$12$gE6CjR1TMzd/z3IFfKMD2Ov2ZAFhinYDb6vfH0Z6BM0TqRaG8TAYi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022950', 'Test User 950', 'user_2022950@example.com', 2024, 'General', '$2b$12$0axLtCmKyIiuXP6HlrqE.OqRQwT7AbTmTez04PAgr0vcX5oWOOaQO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022951', 'Test User 951', 'user_2022951@example.com', 2025, 'General', '$2b$12$tskhdb//KFj23jeu61EsmelOVdZPYV256/S2cgBDyplOKqfFxmQk.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022952', 'Test User 952', 'user_2022952@example.com', 2022, 'General', '$2b$12$AL1NpymVF3fH/.HDNnrJ/.ew2ABRYJZzkFK1DZhZ7rO9nh5kfgNE2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022953', 'Test User 953', 'user_2022953@example.com', 2022, 'General', '$2b$12$RImDZZHKxwCY3Qr1xc4rBO4yGHcD7L8SOuKLy./BAPdzIq1X39.Xi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022954', 'Test User 954', 'user_2022954@example.com', 2023, 'General', '$2b$12$9NcVJjLQPVmzEOTCVMu0vOzTOL91EbNqrDI34Qqt.I.z2GDc9/lHC') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022955', 'Test User 955', 'user_2022955@example.com', 2023, 'General', '$2b$12$NkYnG70PkLcP3hcvg1ACx.l7hWGTdrdMCzSMXaaM0icH61xvhKwga') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022956', 'Test User 956', 'user_2022956@example.com', 2025, 'General', '$2b$12$DHfXr3TFHxTdoY1rpnAFsu1GXJMxGc3d7NSBhm8CHi6n.QDiJEKTq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022957', 'Test User 957', 'user_2022957@example.com', 2023, 'General', '$2b$12$4UEYDHywQAi/8v0djqwqZ.Z9kXYOZiaB4olq1wBQDjBciS5kOtTIa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022958', 'Test User 958', 'user_2022958@example.com', 2022, 'General', '$2b$12$XEKFStHcd52efBdQYYxliO4STO18A4Z5bQQVtohZj63kkF7m6agMO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022959', 'Test User 959', 'user_2022959@example.com', 2023, 'General', '$2b$12$KLjjPT8OZ8dv6.hit9xI9eYGQEAUfWfrdB8lXnxLxKWAPmFEPEUEu') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022960', 'Test User 960', 'user_2022960@example.com', 2023, 'General', '$2b$12$ZJr5ENuyTJLc33bq0mQrwuS2MiY5qOzAFKrVgtLwWWDQDm15sikAO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022961', 'Test User 961', 'user_2022961@example.com', 2022, 'General', '$2b$12$1328TSh48GlgVwmqR3PWau.x87yF8gAXYw7UhyhkPI9quD/4PyW8q') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022962', 'Test User 962', 'user_2022962@example.com', 2024, 'General', '$2b$12$BrOc721FYxZGJf.XqfLHHenCuL5ee7/lUrw4SytrXzSGVKhld3Op2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022963', 'Test User 963', 'user_2022963@example.com', 2024, 'General', '$2b$12$sihqkOn/ObGtw8Dqlhv7seL4OFU0B4C6t675pngI2ljLCevhSC452') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022964', 'Test User 964', 'user_2022964@example.com', 2025, 'General', '$2b$12$.MWls4zuQjtmmRxWc5P59Oc6v1bDZ65jZ2x2lDIf5WgzJDBNzprhq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022965', 'Test User 965', 'user_2022965@example.com', 2023, 'General', '$2b$12$DinMM5zToTUlN5bR6Q/OCeWL.RpdF8TLFCC3GdFAgR2IE/Bfv2MNy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022966', 'Test User 966', 'user_2022966@example.com', 2024, 'General', '$2b$12$lfZE3oa9.jNY0xiNKbDEBuZhdo0vNoMxjkCEBbcW76yYq4D6G9ioa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022967', 'Test User 967', 'user_2022967@example.com', 2022, 'General', '$2b$12$09eLhheuQOo/iU3itJrFcONxCgJbxcYEqrSkD.4g.yQramcVbnAby') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022968', 'Test User 968', 'user_2022968@example.com', 2024, 'General', '$2b$12$AJwJ/u9GJRmT1MarYYja9erLlebviMCw91DxPIMm3UwUvrZ9DmIEy') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022969', 'Test User 969', 'user_2022969@example.com', 2024, 'General', '$2b$12$W3Yhb3WQbloSu5nTR3ELU.5Y02eBUskgBl7u7gUojozrKMuJg433C') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022970', 'Test User 970', 'user_2022970@example.com', 2025, 'General', '$2b$12$gdNi0rxPiMWMdzzVK8Oh.Ojpp.YRgBZo8XkgZVXQEClHHNDMf8E9O') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022971', 'Test User 971', 'user_2022971@example.com', 2022, 'General', '$2b$12$.G9HnTwHxty7GwIkwgff5OFRjhcx6nHKIiHtvcTfc8Awo7LIuyBCS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022972', 'Test User 972', 'user_2022972@example.com', 2022, 'General', '$2b$12$6riA4Q8zNjOXxWuzNes/1OigF0fIo3r5FaJZkZS3efzSRV9YIpORW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022973', 'Test User 973', 'user_2022973@example.com', 2023, 'General', '$2b$12$xFMuUcNAkrbryVlvL8E.ve0brUEd7GAAhaiGaXXtzMvAhPivnwOaK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022974', 'Test User 974', 'user_2022974@example.com', 2024, 'General', '$2b$12$QtmMoK.vSCPsTAZwEOln3ewlvYNwKXKHbdzh3my4kz/ZJyF9nntIO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022975', 'Test User 975', 'user_2022975@example.com', 2024, 'General', '$2b$12$6a75SjCt2f/ezNW7DRGbbOHwm8eEZxXX3pncIqj7AkdwiNAHu7.SW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022976', 'Test User 976', 'user_2022976@example.com', 2023, 'General', '$2b$12$dYzOwedHorL1CCX.tHyMbeZNS2TPXjYBVY/5spLz.FkVbkhJXv/m.') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022977', 'Test User 977', 'user_2022977@example.com', 2023, 'General', '$2b$12$VHEu0bGx5ZySGSVrDL4DruOqZm5TGRL.cFNYiHjwg444D8rIIuGsW') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022978', 'Test User 978', 'user_2022978@example.com', 2022, 'General', '$2b$12$DSYo0eeR5ipVDXCiDUgjt.VWiMZLsltgMkWEE1T3QfFpZMtRpEhBS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022979', 'Test User 979', 'user_2022979@example.com', 2023, 'General', '$2b$12$vpdr3AHz6xhuNKfbrZigIe/GMGeu5n4eNYs2G3UTyyW38J1gP/0f2') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022980', 'Test User 980', 'user_2022980@example.com', 2022, 'General', '$2b$12$MXHZhtnrBVXmtJA7vrVgA.ThdK/ERpElopco5D8FgaG6xIuXDsWLS') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022981', 'Test User 981', 'user_2022981@example.com', 2023, 'General', '$2b$12$uCd79m2PMGNQito6TCX8YupnwFY8T.N3IEEx5L9xTjiJBWITT0nRG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022982', 'Test User 982', 'user_2022982@example.com', 2024, 'General', '$2b$12$tkqhsGXET8rcKkKnl9uG2./sl1zSZ8VQpDR7NK8iqBwKaM//X35ay') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022983', 'Test User 983', 'user_2022983@example.com', 2023, 'General', '$2b$12$9AgOrjzIuVWllhFcoqIEDeyi7pcDTLgWlKY.iNBQw1FRlze6SEWz6') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022984', 'Test User 984', 'user_2022984@example.com', 2024, 'General', '$2b$12$wQlc758YKA/wSYjQGqSLt.e1tz5Xm2TVn2IFAOSgS1scaDRSa0aVq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022985', 'Test User 985', 'user_2022985@example.com', 2024, 'General', '$2b$12$1Dkgk2.BbyR8V9XL9vV6IuN8nj1Gf6/0wKtCwTkPvNd7KXQ66UykO') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022986', 'Test User 986', 'user_2022986@example.com', 2022, 'General', '$2b$12$P2dQzfVpOxUqKOs0Gv/BAulfG4DV6gJYETtN52GpIKxvPan2OeWie') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022987', 'Test User 987', 'user_2022987@example.com', 2024, 'General', '$2b$12$a5ipKLrvb5KCuRyPgAhXbelVi3vpAqdigtpwujvnXrHuDjbnwI44G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022988', 'Test User 988', 'user_2022988@example.com', 2025, 'General', '$2b$12$pscaRBMnGANJpibUUiUrpufHLCVI1f00nlYF2alLyyIW2UF05Pibq') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022989', 'Test User 989', 'user_2022989@example.com', 2023, 'General', '$2b$12$GcAyHicL9FwWPLu0SdVHkeHdVXmOBDjtZUzy/eZ8VGeqWeqzV/5/G') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022990', 'Test User 990', 'user_2022990@example.com', 2024, 'General', '$2b$12$/gUMiM5rqA/toemBaTtCP.Ep/A7nKoINLkNCkYHNa7id2Ue9YiYSa') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022991', 'Test User 991', 'user_2022991@example.com', 2023, 'General', '$2b$12$QKA5iWvzTVv5.H0RJqVPrOc9vgSX9phfeS7LajEtsyL5WStssA1qG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022992', 'Test User 992', 'user_2022992@example.com', 2023, 'General', '$2b$12$604HidfQlwMM/bYx6kMBXezE.AjyFtCTCuuxTBpvKrDc6iuh.wxIK') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022993', 'Test User 993', 'user_2022993@example.com', 2024, 'General', '$2b$12$zGDLwrpbvDjZVL01/YYOtuv19mnhOT0qDDNtadacBzxuyxxjmnpEi') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022994', 'Test User 994', 'user_2022994@example.com', 2024, 'General', '$2b$12$.B8kO8euWQUvqGGGD2uXi.kMWXz9MrXwa59jLT.IFotww42tnjd0S') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022995', 'Test User 995', 'user_2022995@example.com', 2025, 'General', '$2b$12$Qf89X44q4SWdCAD68n/1g.TxxLVVZW0hAFLnfXJ5QYNcDbHOTj2sG') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022996', 'Test User 996', 'user_2022996@example.com', 2025, 'General', '$2b$12$Clh/T/JjSv5GWy55GEbIdeWQlxYfB96SpMVb4gfo.w6VnJC4UP3Ry') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022997', 'Test User 997', 'user_2022997@example.com', 2022, 'General', '$2b$12$wjHIicWnamlcQ6or53p8P.jarAUsKpAs7xhqWeK7J49eY3KMWHLAm') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022998', 'Test User 998', 'user_2022998@example.com', 2022, 'General', '$2b$12$uSEK5iYMyNRADFxhSm2snujCAEtZhs6Tfxw9ALLd4Z2rmAjFWj00y') ON CONFLICT DO NOTHING;
INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('2022999', 'Test User 999', 'user_2022999@example.com', 2022, 'General', '$2b$12$iqCFxp9jFj6TbftU0XK2y.t74jrEgnZCMGoWvg7ZAE47Qutuyw6DG') ON CONFLICT DO NOTHING;

-- ==========================================
-- 3. GENERATE FOLLOWS
-- ==========================================
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022000', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022000', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022000', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022000', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022001', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022001', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022001', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022001', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022002', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022002', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022002', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022002', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022003', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022003', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022003', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022003', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022004', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022004', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022004', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022004', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022005', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022005', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022005', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022005', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022006', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022006', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022006', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022006', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022007', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022007', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022007', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022007', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022008', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022008', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022008', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022008', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022009', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022009', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022009', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022009', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022010', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022010', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022010', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022010', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022011', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022011', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022011', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022011', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022012', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022012', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022012', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022012', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022013', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022013', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022013', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022013', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022014', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022014', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022014', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022014', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022015', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022015', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022015', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022015', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022016', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022016', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022016', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022016', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022017', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022017', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022017', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022017', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022018', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022018', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022018', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022018', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022019', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022019', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022019', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022019', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022020', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022020', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022020', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022020', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022021', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022021', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022021', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022021', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022022', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022022', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022022', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022022', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022023', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022023', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022023', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022023', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022024', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022024', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022024', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022024', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022025', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022025', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022025', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022025', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022026', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022026', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022026', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022026', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022027', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022027', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022027', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022027', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022028', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022028', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022028', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022028', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022029', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022029', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022029', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022029', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022030', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022030', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022030', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022030', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022031', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022031', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022031', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022031', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022032', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022032', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022032', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022032', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022033', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022033', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022033', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022033', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022034', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022034', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022034', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022034', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022035', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022035', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022035', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022035', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022036', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022036', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022036', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022036', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022037', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022037', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022037', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022037', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022038', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022038', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022038', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022038', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022039', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022039', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022039', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022039', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022040', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022040', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022040', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022040', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022041', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022041', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022041', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022041', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022042', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022042', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022042', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022042', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022043', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022043', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022043', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022043', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022044', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022044', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022044', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022044', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022045', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022045', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022045', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022045', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022046', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022046', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022046', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022046', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022047', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022047', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022047', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022047', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022048', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022048', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022048', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022048', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022049', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022049', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022049', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022049', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022050', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022050', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022050', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022050', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022051', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022051', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022051', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022051', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022052', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022052', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022052', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022052', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022053', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022053', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022053', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022053', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022054', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022054', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022054', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022054', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022055', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022055', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022055', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022055', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022056', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022056', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022056', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022056', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022057', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022057', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022057', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022057', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022058', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022058', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022058', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022058', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022059', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022059', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022059', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022059', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022060', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022060', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022060', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022060', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022061', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022061', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022061', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022061', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022062', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022062', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022062', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022062', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022063', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022063', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022063', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022063', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022064', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022064', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022064', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022064', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022065', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022065', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022065', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022065', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022066', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022066', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022066', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022066', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022067', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022067', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022067', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022067', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022068', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022068', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022068', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022068', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022069', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022069', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022069', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022069', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022070', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022070', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022070', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022070', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022071', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022071', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022071', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022071', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022072', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022072', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022072', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022072', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022073', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022073', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022073', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022073', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022074', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022074', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022074', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022074', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022075', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022075', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022075', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022075', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022076', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022076', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022076', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022076', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022077', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022077', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022077', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022077', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022078', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022078', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022078', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022078', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022079', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022079', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022079', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022079', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022080', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022080', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022080', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022080', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022081', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022081', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022081', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022081', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022082', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022082', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022082', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022082', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022083', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022083', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022083', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022083', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022084', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022084', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022084', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022084', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022085', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022085', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022085', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022085', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022086', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022086', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022086', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022086', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022087', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022087', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022087', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022087', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022088', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022088', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022088', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022088', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022089', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022089', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022089', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022089', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022090', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022090', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022090', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022090', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022091', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022091', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022091', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022091', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022092', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022092', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022092', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022092', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022093', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022093', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022093', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022093', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022094', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022094', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022094', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022094', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022095', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022095', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022095', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022095', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022096', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022096', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022096', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022096', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022097', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022097', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022097', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022097', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022098', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022098', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022098', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022098', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022099', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022099', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022099', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022099', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022100', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022100', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022100', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022100', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022101', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022101', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022101', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022101', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022102', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022102', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022102', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022102', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022103', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022103', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022103', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022103', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022104', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022104', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022104', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022104', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022105', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022105', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022105', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022105', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022106', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022106', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022106', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022106', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022107', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022107', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022107', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022107', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022108', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022108', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022108', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022108', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022109', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022109', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022109', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022109', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022110', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022110', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022110', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022110', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022111', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022111', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022111', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022111', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022112', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022112', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022112', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022112', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022113', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022113', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022113', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022113', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022114', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022114', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022114', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022114', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022115', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022115', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022115', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022115', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022116', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022116', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022116', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022116', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022117', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022117', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022117', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022117', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022118', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022118', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022118', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022118', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022119', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022119', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022119', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022119', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022120', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022120', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022120', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022120', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022121', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022121', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022121', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022121', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022122', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022122', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022122', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022122', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022123', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022123', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022123', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022123', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022124', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022124', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022124', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022124', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022125', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022125', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022125', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022125', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022126', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022126', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022126', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022126', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022127', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022127', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022127', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022127', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022128', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022128', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022128', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022128', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022129', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022129', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022129', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022129', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022130', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022130', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022130', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022130', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022131', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022131', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022131', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022131', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022132', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022132', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022132', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022132', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022133', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022133', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022133', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022133', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022134', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022134', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022134', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022134', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022135', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022135', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022135', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022135', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022136', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022136', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022136', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022136', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022137', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022137', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022137', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022137', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022138', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022138', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022138', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022138', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022139', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022139', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022139', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022139', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022140', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022140', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022140', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022140', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022141', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022141', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022141', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022141', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022142', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022142', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022142', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022142', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022143', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022143', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022143', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022143', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022144', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022144', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022144', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022144', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022145', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022145', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022145', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022145', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022146', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022146', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022146', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022146', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022147', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022147', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022147', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022147', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022148', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022148', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022148', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022148', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022149', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022149', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022149', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022149', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022150', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022150', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022150', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022150', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022151', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022151', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022151', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022151', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022152', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022152', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022152', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022152', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022153', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022153', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022153', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022153', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022154', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022154', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022154', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022154', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022155', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022155', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022155', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022155', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022156', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022156', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022156', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022156', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022157', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022157', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022157', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022157', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022158', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022158', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022158', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022158', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022159', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022159', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022159', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022159', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022160', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022160', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022160', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022160', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022161', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022161', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022161', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022161', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022162', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022162', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022162', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022162', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022163', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022163', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022163', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022163', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022164', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022164', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022164', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022164', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022165', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022165', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022165', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022165', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022166', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022166', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022166', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022166', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022167', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022167', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022167', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022167', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022168', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022168', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022168', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022168', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022169', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022169', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022169', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022169', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022170', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022170', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022170', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022170', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022171', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022171', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022171', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022171', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022172', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022172', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022172', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022172', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022173', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022173', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022173', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022173', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022174', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022174', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022174', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022174', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022175', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022175', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022175', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022175', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022176', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022176', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022176', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022176', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022177', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022177', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022177', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022177', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022178', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022178', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022178', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022178', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022179', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022179', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022179', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022179', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022180', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022180', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022180', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022180', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022181', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022181', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022181', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022181', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022182', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022182', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022182', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022182', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022183', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022183', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022183', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022183', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022184', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022184', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022184', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022184', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022185', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022185', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022185', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022185', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022186', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022186', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022186', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022186', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022187', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022187', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022187', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022187', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022188', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022188', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022188', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022188', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022189', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022189', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022189', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022189', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022190', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022190', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022190', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022190', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022191', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022191', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022191', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022191', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022192', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022192', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022192', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022192', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022193', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022193', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022193', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022193', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022194', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022194', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022194', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022194', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022195', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022195', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022195', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022195', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022196', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022196', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022196', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022196', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022197', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022197', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022197', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022197', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022198', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022198', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022198', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022198', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022199', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022199', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022199', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022199', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022200', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022200', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022200', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022200', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022201', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022201', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022201', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022201', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022202', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022202', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022202', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022202', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022203', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022203', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022203', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022203', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022204', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022204', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022204', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022204', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022205', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022205', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022205', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022205', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022206', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022206', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022206', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022206', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022207', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022207', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022207', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022207', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022208', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022208', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022208', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022208', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022209', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022209', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022209', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022209', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022210', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022210', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022210', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022210', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022211', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022211', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022211', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022211', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022212', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022212', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022212', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022212', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022213', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022213', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022213', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022213', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022214', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022214', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022214', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022214', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022215', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022215', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022215', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022215', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022216', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022216', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022216', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022216', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022217', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022217', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022217', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022217', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022218', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022218', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022218', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022218', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022219', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022219', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022219', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022219', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022220', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022220', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022220', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022220', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022221', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022221', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022221', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022221', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022222', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022222', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022222', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022222', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022223', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022223', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022223', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022223', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022224', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022224', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022224', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022224', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022225', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022225', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022225', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022225', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022226', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022226', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022226', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022226', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022227', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022227', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022227', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022227', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022228', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022228', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022228', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022228', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022229', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022229', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022229', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022229', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022230', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022230', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022230', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022230', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022231', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022231', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022231', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022231', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022232', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022232', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022232', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022232', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022233', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022233', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022233', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022233', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022234', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022234', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022234', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022234', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022235', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022235', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022235', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022235', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022236', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022236', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022236', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022236', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022237', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022237', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022237', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022237', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022238', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022238', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022238', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022238', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022239', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022239', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022239', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022239', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022240', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022240', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022240', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022240', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022241', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022241', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022241', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022241', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022242', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022242', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022242', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022242', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022243', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022243', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022243', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022243', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022244', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022244', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022244', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022244', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022245', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022245', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022245', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022245', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022246', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022246', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022246', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022246', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022247', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022247', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022247', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022247', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022248', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022248', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022248', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022248', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022249', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022249', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022249', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022249', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022250', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022250', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022250', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022250', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022251', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022251', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022251', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022251', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022252', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022252', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022252', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022252', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022253', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022253', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022253', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022253', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022254', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022254', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022254', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022254', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022255', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022255', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022255', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022255', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022256', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022256', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022256', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022256', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022257', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022257', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022257', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022257', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022258', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022258', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022258', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022258', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022259', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022259', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022259', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022259', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022260', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022260', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022260', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022260', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022261', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022261', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022261', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022261', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022262', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022262', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022262', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022262', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022263', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022263', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022263', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022263', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022264', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022264', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022264', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022264', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022265', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022265', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022265', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022265', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022266', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022266', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022266', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022266', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022267', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022267', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022267', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022267', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022268', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022268', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022268', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022268', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022269', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022269', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022269', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022269', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022270', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022270', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022270', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022270', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022271', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022271', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022271', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022271', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022272', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022272', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022272', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022272', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022273', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022273', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022273', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022273', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022274', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022274', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022274', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022274', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022275', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022275', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022275', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022275', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022276', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022276', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022276', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022276', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022277', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022277', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022277', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022277', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022278', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022278', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022278', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022278', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022279', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022279', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022279', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022279', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022280', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022280', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022280', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022280', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022281', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022281', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022281', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022281', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022282', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022282', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022282', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022282', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022283', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022283', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022283', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022283', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022284', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022284', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022284', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022284', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022285', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022285', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022285', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022285', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022286', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022286', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022286', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022286', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022287', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022287', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022287', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022287', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022288', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022288', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022288', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022288', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022289', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022289', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022289', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022289', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022290', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022290', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022290', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022290', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022291', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022291', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022291', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022291', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022292', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022292', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022292', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022292', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022293', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022293', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022293', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022293', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022294', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022294', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022294', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022294', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022295', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022295', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022295', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022295', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022296', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022296', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022296', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022296', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022297', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022297', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022297', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022297', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022298', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022298', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022298', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022298', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022299', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022299', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022299', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022299', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022300', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022300', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022300', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022300', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022301', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022301', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022301', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022301', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022302', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022302', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022302', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022302', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022303', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022303', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022303', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022303', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022304', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022304', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022304', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022304', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022305', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022305', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022305', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022305', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022306', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022306', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022306', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022306', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022307', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022307', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022307', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022307', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022308', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022308', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022308', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022308', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022309', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022309', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022309', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022309', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022310', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022310', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022310', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022310', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022311', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022311', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022311', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022311', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022312', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022312', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022312', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022312', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022313', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022313', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022313', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022313', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022314', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022314', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022314', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022314', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022315', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022315', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022315', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022315', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022316', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022316', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022316', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022316', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022317', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022317', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022317', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022317', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022318', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022318', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022318', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022318', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022319', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022319', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022319', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022319', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022320', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022320', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022320', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022320', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022321', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022321', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022321', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022321', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022322', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022322', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022322', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022322', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022323', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022323', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022323', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022323', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022324', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022324', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022324', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022324', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022325', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022325', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022325', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022325', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022326', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022326', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022326', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022326', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022327', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022327', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022327', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022327', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022328', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022328', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022328', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022328', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022329', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022329', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022329', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022329', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022330', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022330', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022330', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022330', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022331', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022331', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022331', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022331', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022332', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022332', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022332', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022332', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022333', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022333', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022333', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022333', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022334', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022334', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022334', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022334', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022335', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022335', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022335', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022335', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022336', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022336', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022336', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022336', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022337', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022337', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022337', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022337', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022338', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022338', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022338', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022338', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022339', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022339', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022339', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022339', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022340', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022340', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022340', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022340', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022341', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022341', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022341', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022341', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022342', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022342', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022342', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022342', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022343', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022343', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022343', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022343', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022344', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022344', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022344', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022344', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022345', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022345', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022345', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022345', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022346', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022346', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022346', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022346', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022347', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022347', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022347', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022347', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022348', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022348', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022348', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022348', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022349', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022349', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022349', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022349', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022350', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022350', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022350', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022350', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022351', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022351', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022351', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022351', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022352', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022352', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022352', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022352', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022353', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022353', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022353', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022353', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022354', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022354', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022354', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022354', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022355', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022355', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022355', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022355', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022356', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022356', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022356', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022356', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022357', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022357', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022357', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022357', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022358', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022358', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022358', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022358', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022359', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022359', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022359', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022359', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022360', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022360', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022360', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022360', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022361', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022361', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022361', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022361', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022362', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022362', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022362', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022362', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022363', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022363', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022363', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022363', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022364', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022364', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022364', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022364', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022365', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022365', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022365', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022365', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022366', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022366', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022366', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022366', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022367', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022367', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022367', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022367', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022368', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022368', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022368', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022368', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022369', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022369', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022369', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022369', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022370', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022370', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022370', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022370', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022371', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022371', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022371', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022371', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022372', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022372', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022372', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022372', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022373', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022373', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022373', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022373', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022374', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022374', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022374', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022374', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022375', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022375', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022375', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022375', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022376', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022376', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022376', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022376', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022377', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022377', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022377', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022377', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022378', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022378', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022378', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022378', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022379', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022379', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022379', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022379', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022380', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022380', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022380', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022380', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022381', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022381', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022381', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022381', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022382', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022382', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022382', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022382', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022383', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022383', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022383', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022383', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022384', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022384', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022384', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022384', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022385', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022385', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022385', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022385', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022386', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022386', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022386', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022386', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022387', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022387', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022387', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022387', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022388', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022388', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022388', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022388', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022389', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022389', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022389', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022389', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022390', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022390', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022390', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022390', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022391', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022391', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022391', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022391', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022392', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022392', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022392', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022392', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022393', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022393', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022393', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022393', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022394', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022394', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022394', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022394', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022395', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022395', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022395', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022395', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022396', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022396', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022396', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022396', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022397', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022397', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022397', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022397', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022398', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022398', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022398', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022398', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022399', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022399', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022399', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022399', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022400', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022400', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022400', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022400', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022401', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022401', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022401', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022401', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022402', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022402', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022402', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022402', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022403', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022403', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022403', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022403', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022404', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022404', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022404', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022404', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022405', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022405', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022405', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022405', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022406', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022406', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022406', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022406', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022407', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022407', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022407', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022407', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022408', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022408', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022408', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022408', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022409', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022409', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022409', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022409', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022410', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022410', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022410', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022410', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022411', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022411', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022411', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022411', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022412', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022412', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022412', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022412', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022413', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022413', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022413', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022413', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022414', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022414', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022414', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022414', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022415', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022415', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022415', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022415', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022416', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022416', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022416', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022416', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022417', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022417', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022417', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022417', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022418', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022418', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022418', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022418', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022419', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022419', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022419', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022419', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022420', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022420', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022420', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022420', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022421', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022421', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022421', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022421', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022422', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022422', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022422', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022422', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022423', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022423', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022423', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022423', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022424', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022424', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022424', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022424', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022425', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022425', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022425', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022425', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022426', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022426', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022426', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022426', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022427', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022427', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022427', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022427', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022428', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022428', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022428', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022428', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022429', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022429', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022429', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022429', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022430', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022430', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022430', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022430', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022431', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022431', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022431', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022431', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022432', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022432', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022432', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022432', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022433', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022433', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022433', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022433', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022434', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022434', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022434', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022434', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022435', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022435', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022435', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022435', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022436', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022436', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022436', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022436', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022437', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022437', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022437', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022437', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022438', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022438', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022438', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022438', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022439', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022439', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022439', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022439', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022440', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022440', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022440', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022440', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022441', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022441', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022441', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022441', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022442', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022442', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022442', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022442', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022443', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022443', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022443', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022443', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022444', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022444', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022444', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022444', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022445', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022445', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022445', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022445', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022446', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022446', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022446', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022446', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022447', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022447', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022447', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022447', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022448', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022448', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022448', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022448', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022449', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022449', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022449', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022449', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022450', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022450', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022450', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022450', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022451', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022451', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022451', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022451', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022452', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022452', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022452', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022452', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022453', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022453', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022453', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022453', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022454', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022454', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022454', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022454', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022455', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022455', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022455', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022455', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022456', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022456', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022456', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022456', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022457', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022457', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022457', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022457', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022458', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022458', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022458', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022458', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022459', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022459', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022459', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022459', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022460', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022460', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022460', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022460', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022461', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022461', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022461', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022461', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022462', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022462', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022462', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022462', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022463', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022463', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022463', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022463', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022464', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022464', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022464', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022464', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022465', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022465', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022465', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022465', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022466', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022466', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022466', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022466', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022467', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022467', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022467', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022467', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022468', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022468', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022468', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022468', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022469', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022469', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022469', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022469', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022470', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022470', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022470', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022470', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022471', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022471', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022471', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022471', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022472', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022472', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022472', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022472', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022473', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022473', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022473', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022473', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022474', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022474', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022474', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022474', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022475', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022475', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022475', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022475', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022476', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022476', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022476', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022476', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022477', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022477', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022477', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022477', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022478', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022478', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022478', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022478', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022479', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022479', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022479', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022479', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022480', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022480', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022480', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022480', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022481', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022481', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022481', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022481', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022482', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022482', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022482', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022482', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022483', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022483', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022483', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022483', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022484', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022484', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022484', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022484', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022485', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022485', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022485', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022485', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022486', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022486', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022486', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022486', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022487', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022487', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022487', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022487', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022488', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022488', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022488', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022488', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022489', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022489', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022489', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022489', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022490', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022490', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022490', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022490', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022491', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022491', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022491', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022491', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022492', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022492', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022492', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022492', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022493', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022493', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022493', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022493', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022494', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022494', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022494', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022494', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022495', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022495', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022495', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022495', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022496', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022496', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022496', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022496', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022497', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022497', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022497', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022497', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022498', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022498', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022498', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022498', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022499', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022499', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022499', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022499', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022500', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022500', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022500', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022500', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022501', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022501', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022501', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022501', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022502', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022502', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022502', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022502', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022503', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022503', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022503', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022503', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022504', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022504', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022504', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022504', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022505', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022505', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022505', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022505', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022506', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022506', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022506', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022506', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022507', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022507', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022507', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022507', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022508', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022508', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022508', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022508', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022509', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022509', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022509', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022509', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022510', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022510', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022510', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022510', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022511', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022511', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022511', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022511', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022512', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022512', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022512', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022512', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022513', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022513', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022513', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022513', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022514', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022514', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022514', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022514', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022515', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022515', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022515', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022515', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022516', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022516', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022516', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022516', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022517', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022517', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022517', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022517', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022518', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022518', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022518', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022518', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022519', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022519', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022519', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022519', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022520', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022520', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022520', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022520', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022521', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022521', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022521', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022521', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022522', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022522', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022522', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022522', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022523', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022523', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022523', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022523', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022524', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022524', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022524', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022524', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022525', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022525', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022525', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022525', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022526', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022526', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022526', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022526', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022527', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022527', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022527', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022527', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022528', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022528', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022528', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022528', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022529', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022529', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022529', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022529', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022530', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022530', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022530', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022530', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022531', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022531', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022531', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022531', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022532', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022532', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022532', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022532', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022533', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022533', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022533', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022533', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022534', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022534', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022534', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022534', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022535', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022535', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022535', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022535', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022536', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022536', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022536', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022536', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022537', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022537', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022537', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022537', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022538', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022538', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022538', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022538', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022539', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022539', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022539', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022539', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022540', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022540', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022540', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022540', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022541', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022541', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022541', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022541', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022542', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022542', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022542', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022542', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022543', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022543', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022543', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022543', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022544', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022544', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022544', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022544', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022545', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022545', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022545', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022545', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022546', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022546', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022546', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022546', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022547', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022547', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022547', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022547', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022548', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022548', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022548', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022548', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022549', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022549', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022549', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022549', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022550', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022550', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022550', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022550', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022551', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022551', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022551', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022551', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022552', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022552', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022552', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022552', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022553', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022553', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022553', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022553', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022554', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022554', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022554', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022554', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022555', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022555', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022555', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022555', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022556', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022556', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022556', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022556', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022557', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022557', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022557', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022557', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022558', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022558', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022558', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022558', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022559', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022559', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022559', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022559', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022560', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022560', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022560', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022560', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022561', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022561', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022561', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022561', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022562', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022562', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022562', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022562', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022563', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022563', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022563', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022563', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022564', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022564', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022564', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022564', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022565', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022565', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022565', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022565', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022566', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022566', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022566', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022566', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022567', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022567', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022567', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022567', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022568', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022568', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022568', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022568', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022569', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022569', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022569', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022569', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022570', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022570', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022570', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022570', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022571', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022571', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022571', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022571', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022572', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022572', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022572', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022572', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022573', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022573', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022573', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022573', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022574', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022574', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022574', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022574', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022575', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022575', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022575', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022575', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022576', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022576', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022576', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022576', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022577', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022577', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022577', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022577', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022578', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022578', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022578', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022578', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022579', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022579', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022579', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022579', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022580', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022580', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022580', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022580', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022581', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022581', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022581', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022581', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022582', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022582', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022582', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022582', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022583', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022583', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022583', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022583', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022584', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022584', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022584', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022584', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022585', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022585', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022585', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022585', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022586', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022586', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022586', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022586', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022587', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022587', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022587', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022587', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022588', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022588', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022588', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022588', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022589', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022589', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022589', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022589', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022590', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022590', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022590', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022590', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022591', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022591', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022591', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022591', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022592', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022592', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022592', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022592', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022593', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022593', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022593', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022593', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022594', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022594', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022594', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022594', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022595', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022595', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022595', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022595', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022596', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022596', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022596', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022596', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022597', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022597', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022597', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022597', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022598', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022598', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022598', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022598', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022599', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022599', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022599', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022599', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022600', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022600', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022600', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022600', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022601', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022601', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022601', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022601', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022602', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022602', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022602', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022602', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022603', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022603', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022603', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022603', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022604', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022604', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022604', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022604', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022605', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022605', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022605', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022605', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022606', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022606', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022606', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022606', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022607', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022607', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022607', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022607', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022608', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022608', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022608', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022608', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022609', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022609', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022609', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022609', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022610', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022610', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022610', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022610', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022611', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022611', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022611', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022611', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022612', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022612', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022612', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022612', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022613', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022613', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022613', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022613', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022614', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022614', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022614', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022614', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022615', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022615', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022615', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022615', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022616', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022616', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022616', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022616', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022617', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022617', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022617', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022617', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022618', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022618', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022618', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022618', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022619', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022619', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022619', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022619', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022620', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022620', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022620', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022620', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022621', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022621', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022621', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022621', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022622', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022622', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022622', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022622', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022623', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022623', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022623', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022623', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022624', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022624', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022624', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022624', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022625', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022625', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022625', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022625', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022626', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022626', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022626', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022626', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022627', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022627', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022627', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022627', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022628', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022628', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022628', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022628', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022629', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022629', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022629', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022629', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022630', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022630', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022630', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022630', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022631', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022631', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022631', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022631', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022632', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022632', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022632', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022632', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022633', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022633', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022633', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022633', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022634', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022634', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022634', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022634', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022635', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022635', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022635', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022635', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022636', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022636', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022636', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022636', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022637', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022637', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022637', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022637', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022638', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022638', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022638', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022638', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022639', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022639', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022639', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022639', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022640', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022640', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022640', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022640', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022641', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022641', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022641', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022641', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022642', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022642', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022642', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022642', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022643', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022643', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022643', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022643', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022644', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022644', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022644', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022644', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022645', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022645', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022645', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022645', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022646', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022646', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022646', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022646', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022647', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022647', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022647', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022647', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022648', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022648', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022648', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022648', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022649', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022649', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022649', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022649', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022650', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022650', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022650', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022650', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022651', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022651', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022651', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022651', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022652', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022652', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022652', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022652', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022653', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022653', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022653', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022653', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022654', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022654', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022654', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022654', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022655', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022655', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022655', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022655', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022656', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022656', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022656', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022656', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022657', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022657', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022657', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022657', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022658', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022658', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022658', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022658', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022659', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022659', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022659', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022659', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022660', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022660', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022660', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022660', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022661', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022661', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022661', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022661', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022662', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022662', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022662', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022662', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022663', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022663', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022663', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022663', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022664', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022664', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022664', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022664', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022665', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022665', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022665', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022665', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022666', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022666', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022666', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022666', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022667', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022667', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022667', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022667', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022668', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022668', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022668', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022668', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022669', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022669', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022669', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022669', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022670', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022670', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022670', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022670', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022671', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022671', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022671', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022671', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022672', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022672', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022672', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022672', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022673', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022673', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022673', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022673', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022674', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022674', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022674', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022674', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022675', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022675', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022675', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022675', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022676', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022676', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022676', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022676', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022677', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022677', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022677', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022677', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022678', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022678', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022678', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022678', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022679', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022679', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022679', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022679', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022680', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022680', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022680', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022680', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022681', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022681', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022681', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022681', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022682', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022682', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022682', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022682', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022683', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022683', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022683', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022683', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022684', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022684', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022684', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022684', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022685', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022685', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022685', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022685', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022686', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022686', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022686', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022686', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022687', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022687', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022687', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022687', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022688', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022688', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022688', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022688', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022689', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022689', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022689', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022689', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022690', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022690', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022690', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022690', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022691', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022691', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022691', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022691', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022692', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022692', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022692', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022692', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022693', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022693', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022693', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022693', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022694', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022694', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022694', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022694', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022695', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022695', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022695', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022695', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022696', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022696', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022696', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022696', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022697', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022697', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022697', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022697', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022698', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022698', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022698', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022698', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022699', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022699', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022699', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022699', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022700', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022700', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022700', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022700', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022701', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022701', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022701', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022701', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022702', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022702', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022702', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022702', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022703', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022703', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022703', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022703', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022704', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022704', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022704', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022704', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022705', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022705', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022705', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022705', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022706', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022706', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022706', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022706', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022707', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022707', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022707', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022707', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022708', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022708', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022708', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022708', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022709', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022709', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022709', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022709', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022710', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022710', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022710', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022710', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022711', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022711', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022711', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022711', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022712', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022712', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022712', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022712', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022713', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022713', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022713', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022713', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022714', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022714', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022714', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022714', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022715', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022715', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022715', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022715', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022716', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022716', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022716', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022716', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022717', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022717', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022717', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022717', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022718', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022718', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022718', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022718', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022719', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022719', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022719', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022719', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022720', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022720', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022720', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022720', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022721', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022721', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022721', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022721', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022722', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022722', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022722', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022722', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022723', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022723', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022723', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022723', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022724', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022724', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022724', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022724', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022725', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022725', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022725', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022725', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022726', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022726', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022726', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022726', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022727', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022727', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022727', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022727', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022728', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022728', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022728', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022728', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022729', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022729', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022729', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022729', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022730', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022730', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022730', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022730', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022731', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022731', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022731', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022731', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022732', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022732', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022732', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022732', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022733', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022733', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022733', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022733', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022734', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022734', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022734', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022734', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022735', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022735', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022735', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022735', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022736', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022736', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022736', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022736', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022737', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022737', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022737', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022737', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022738', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022738', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022738', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022738', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022739', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022739', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022739', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022739', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022740', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022740', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022740', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022740', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022741', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022741', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022741', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022741', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022742', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022742', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022742', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022742', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022743', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022743', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022743', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022743', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022744', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022744', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022744', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022744', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022745', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022745', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022745', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022745', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022746', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022746', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022746', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022746', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022747', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022747', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022747', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022747', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022748', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022748', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022748', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022748', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022749', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022749', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022749', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022749', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022750', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022750', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022750', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022750', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022751', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022751', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022751', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022751', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022752', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022752', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022752', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022752', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022753', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022753', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022753', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022753', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022754', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022754', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022754', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022754', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022755', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022755', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022755', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022755', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022756', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022756', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022756', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022756', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022757', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022757', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022757', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022757', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022758', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022758', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022758', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022758', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022759', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022759', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022759', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022759', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022760', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022760', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022760', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022760', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022761', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022761', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022761', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022761', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022762', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022762', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022762', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022762', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022763', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022763', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022763', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022763', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022764', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022764', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022764', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022764', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022765', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022765', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022765', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022765', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022766', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022766', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022766', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022766', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022767', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022767', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022767', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022767', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022768', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022768', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022768', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022768', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022769', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022769', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022769', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022769', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022770', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022770', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022770', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022770', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022771', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022771', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022771', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022771', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022772', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022772', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022772', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022772', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022773', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022773', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022773', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022773', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022774', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022774', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022774', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022774', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022775', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022775', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022775', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022775', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022776', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022776', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022776', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022776', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022777', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022777', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022777', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022777', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022778', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022778', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022778', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022778', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022779', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022779', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022779', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022779', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022780', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022780', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022780', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022780', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022781', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022781', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022781', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022781', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022782', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022782', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022782', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022782', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022783', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022783', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022783', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022783', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022784', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022784', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022784', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022784', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022785', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022785', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022785', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022785', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022786', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022786', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022786', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022786', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022787', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022787', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022787', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022787', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022788', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022788', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022788', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022788', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022789', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022789', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022789', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022789', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022790', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022790', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022790', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022790', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022791', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022791', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022791', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022791', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022792', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022792', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022792', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022792', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022793', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022793', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022793', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022793', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022794', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022794', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022794', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022794', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022795', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022795', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022795', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022795', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022796', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022796', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022796', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022796', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022797', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022797', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022797', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022797', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022798', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022798', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022798', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022798', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022799', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022799', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022799', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022799', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022800', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022800', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022800', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022800', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022801', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022801', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022801', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022801', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022802', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022802', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022802', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022802', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022803', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022803', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022803', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022803', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022804', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022804', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022804', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022804', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022805', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022805', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022805', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022805', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022806', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022806', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022806', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022806', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022807', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022807', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022807', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022807', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022808', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022808', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022808', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022808', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022809', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022809', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022809', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022809', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022810', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022810', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022810', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022810', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022811', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022811', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022811', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022811', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022812', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022812', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022812', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022812', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022813', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022813', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022813', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022813', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022814', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022814', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022814', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022814', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022815', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022815', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022815', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022815', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022816', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022816', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022816', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022816', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022817', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022817', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022817', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022817', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022818', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022818', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022818', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022818', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022819', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022819', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022819', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022819', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022820', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022820', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022820', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022820', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022821', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022821', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022821', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022821', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022822', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022822', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022822', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022822', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022823', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022823', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022823', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022823', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022824', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022824', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022824', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022824', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022825', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022825', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022825', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022825', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022826', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022826', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022826', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022826', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022827', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022827', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022827', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022827', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022828', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022828', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022828', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022828', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022829', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022829', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022829', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022829', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022830', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022830', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022830', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022830', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022831', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022831', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022831', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022831', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022832', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022832', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022832', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022832', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022833', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022833', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022833', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022833', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022834', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022834', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022834', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022834', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022835', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022835', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022835', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022835', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022836', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022836', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022836', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022836', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022837', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022837', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022837', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022837', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022838', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022838', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022838', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022838', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022839', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022839', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022839', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022839', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022840', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022840', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022840', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022840', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022841', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022841', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022841', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022841', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022842', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022842', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022842', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022842', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022843', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022843', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022843', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022843', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022844', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022844', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022844', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022844', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022845', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022845', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022845', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022845', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022846', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022846', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022846', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022846', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022847', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022847', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022847', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022847', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022848', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022848', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022848', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022848', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022849', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022849', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022849', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022849', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022850', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022850', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022850', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022850', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022851', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022851', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022851', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022851', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022852', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022852', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022852', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022852', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022853', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022853', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022853', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022853', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022854', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022854', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022854', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022854', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022855', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022855', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022855', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022855', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022856', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022856', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022856', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022856', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022857', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022857', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022857', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022857', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022858', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022858', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022858', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022858', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022859', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022859', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022859', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022859', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022860', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022860', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022860', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022860', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022861', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022861', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022861', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022861', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022862', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022862', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022862', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022862', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022863', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022863', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022863', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022863', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022864', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022864', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022864', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022864', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022865', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022865', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022865', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022865', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022866', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022866', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022866', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022866', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022867', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022867', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022867', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022867', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022868', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022868', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022868', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022868', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022869', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022869', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022869', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022869', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022870', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022870', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022870', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022870', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022871', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022871', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022871', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022871', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022872', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022872', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022872', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022872', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022873', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022873', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022873', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022873', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022874', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022874', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022874', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022874', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022875', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022875', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022875', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022875', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022876', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022876', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022876', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022876', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022877', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022877', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022877', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022877', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022878', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022878', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022878', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022878', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022879', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022879', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022879', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022879', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022880', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022880', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022880', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022880', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022881', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022881', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022881', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022881', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022882', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022882', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022882', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022882', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022883', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022883', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022883', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022883', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022884', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022884', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022884', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022884', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022885', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022885', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022885', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022885', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022886', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022886', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022886', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022886', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022887', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022887', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022887', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022887', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022888', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022888', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022888', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022888', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022889', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022889', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022889', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022889', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022890', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022890', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022890', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022890', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022891', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022891', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022891', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022891', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022892', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022892', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022892', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022892', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022893', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022893', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022893', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022893', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022894', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022894', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022894', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022894', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022895', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022895', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022895', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022895', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022896', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022896', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022896', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022896', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022897', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022897', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022897', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022897', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022898', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022898', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022898', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022898', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022899', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022899', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022899', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022899', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022900', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022900', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022900', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022900', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022901', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022901', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022901', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022901', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022902', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022902', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022902', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022902', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022903', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022903', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022903', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022903', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022904', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022904', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022904', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022904', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022905', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022905', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022905', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022905', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022906', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022906', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022906', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022906', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022907', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022907', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022907', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022907', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022908', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022908', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022908', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022908', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022909', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022909', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022909', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022909', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022910', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022910', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022910', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022910', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022911', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022911', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022911', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022911', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022912', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022912', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022912', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022912', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022913', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022913', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022913', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022913', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022914', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022914', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022914', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022914', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022915', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022915', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022915', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022915', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022916', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022916', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022916', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022916', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022917', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022917', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022917', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022917', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022918', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022918', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022918', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022918', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022919', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022919', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022919', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022919', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022920', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022920', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022920', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022920', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022921', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022921', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022921', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022921', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022922', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022922', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022922', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022922', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022923', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022923', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022923', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022923', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022924', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022924', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022924', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022924', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022925', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022925', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022925', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022925', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022926', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022926', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022926', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022926', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022927', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022927', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022927', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022927', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022928', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022928', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022928', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022928', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022929', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022929', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022929', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022929', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022930', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022930', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022930', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022930', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022931', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022931', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022931', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022931', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022932', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022932', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022932', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022932', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022933', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022933', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022933', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022933', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022934', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022934', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022934', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022934', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022935', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022935', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022935', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022935', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022936', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022936', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022936', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022936', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022937', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022937', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022937', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022937', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022938', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022938', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022938', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022938', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022939', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022939', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022939', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022939', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022940', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022940', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022940', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022940', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022941', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022941', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022941', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022941', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022942', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022942', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022942', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022942', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022943', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022943', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022943', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022943', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022944', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022944', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022944', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022944', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022945', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022945', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022945', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022945', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022946', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022946', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022946', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022946', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022947', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022947', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022947', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022947', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022948', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022948', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022948', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022948', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022949', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022949', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022949', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022949', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022950', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022950', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022950', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022950', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022951', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022951', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022951', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022951', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022952', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022952', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022952', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022952', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022953', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022953', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022953', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022953', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022954', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022954', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022954', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022954', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022955', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022955', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022955', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022955', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022956', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022956', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022956', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022956', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022957', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022957', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022957', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022957', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022958', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022958', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022958', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022958', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022959', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022959', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022959', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022959', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022960', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022960', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022960', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022960', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022961', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022961', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022961', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022961', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022962', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022962', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022962', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022962', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022963', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022963', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022963', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022963', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022964', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022964', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022964', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022964', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022965', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022965', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022965', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022965', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022966', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022966', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022966', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022966', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022967', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022967', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022967', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022967', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022968', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022968', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022968', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022968', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022969', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022969', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022969', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022969', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022970', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022970', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022970', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022970', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022971', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022971', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022971', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022971', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022972', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022972', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022972', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022972', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022973', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022973', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022973', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022973', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022974', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022974', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022974', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022974', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022975', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022975', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022975', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022975', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022976', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022976', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022976', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022976', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022977', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022977', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022977', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022977', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022978', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022978', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022978', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022978', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022979', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022979', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022979', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022979', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022980', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022980', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022980', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022980', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022981', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022981', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022981', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022981', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022982', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022982', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022982', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022982', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022983', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022983', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022983', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022983', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022984', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022984', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022984', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022984', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022985', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022985', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022985', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022985', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022986', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022986', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022986', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022986', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022987', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022987', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022987', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022987', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022988', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022988', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022988', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022988', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022989', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022989', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022989', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022989', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022990', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022990', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022990', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022990', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022991', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022991', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022991', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022991', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022992', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022992', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022992', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022992', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022993', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022993', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022993', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022993', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022994', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022994', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022994', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022994', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022995', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022995', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022995', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022995', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022996', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022996', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022996', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022996', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022997', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022997', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022997', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022997', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022998', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022998', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022998', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022998', '2024903') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022999', '2024338') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022999', '2024307') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022999', '2024475') ON CONFLICT DO NOTHING;
INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('2022999', '2024903') ON CONFLICT DO NOTHING;

-- ==========================================
-- 4. GENERATE TRENDING TWEETS (MAIN USERS)
-- ==========================================
DO $$
DECLARE
    t_id INT;
    synth_users VARCHAR[] := ARRAY['2022000','2022001','2022002','2022003','2022004','2022005','2022006','2022007','2022008','2022009','2022010','2022011','2022012','2022013','2022014','2022015','2022016','2022017','2022018','2022019','2022020','2022021','2022022','2022023','2022024','2022025','2022026','2022027','2022028','2022029','2022030','2022031','2022032','2022033','2022034','2022035','2022036','2022037','2022038','2022039','2022040','2022041','2022042','2022043','2022044','2022045','2022046','2022047','2022048','2022049','2022050','2022051','2022052','2022053','2022054','2022055','2022056','2022057','2022058','2022059','2022060','2022061','2022062','2022063','2022064','2022065','2022066','2022067','2022068','2022069','2022070','2022071','2022072','2022073','2022074','2022075','2022076','2022077','2022078','2022079','2022080','2022081','2022082','2022083','2022084','2022085','2022086','2022087','2022088','2022089','2022090','2022091','2022092','2022093','2022094','2022095','2022096','2022097','2022098','2022099','2022100','2022101','2022102','2022103','2022104','2022105','2022106','2022107','2022108','2022109','2022110','2022111','2022112','2022113','2022114','2022115','2022116','2022117','2022118','2022119','2022120','2022121','2022122','2022123','2022124','2022125','2022126','2022127','2022128','2022129','2022130','2022131','2022132','2022133','2022134','2022135','2022136','2022137','2022138','2022139','2022140','2022141','2022142','2022143','2022144','2022145','2022146','2022147','2022148','2022149','2022150','2022151','2022152','2022153','2022154','2022155','2022156','2022157','2022158','2022159','2022160','2022161','2022162','2022163','2022164','2022165','2022166','2022167','2022168','2022169','2022170','2022171','2022172','2022173','2022174','2022175','2022176','2022177','2022178','2022179','2022180','2022181','2022182','2022183','2022184','2022185','2022186','2022187','2022188','2022189','2022190','2022191','2022192','2022193','2022194','2022195','2022196','2022197','2022198','2022199'];
BEGIN
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024307', 'Is anyone else struggling with triggers? - 55') RETURNING tweet_id INTO t_id;
    FOR i IN 1..104 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024338', 'Is anyone else struggling with triggers? - 67') RETURNING tweet_id INTO t_id;
    FOR i IN 1..85 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024903', 'PostgreSQL rocks! - 39') RETURNING tweet_id INTO t_id;
    FOR i IN 1..64 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024903', 'Testing the massive synthetic dataset now! - 6') RETURNING tweet_id INTO t_id;
    FOR i IN 1..56 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024338', 'Can''t believe how much data we are generating. - 84') RETURNING tweet_id INTO t_id;
    FOR i IN 1..63 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024475', 'Final year projects are stressful but fun. - 24') RETURNING tweet_id INTO t_id;
    FOR i IN 1..119 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024475', 'Just working on the new database project! #CS - 37') RETURNING tweet_id INTO t_id;
    FOR i IN 1..52 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024475', 'Just working on the new database project! #CS - 87') RETURNING tweet_id INTO t_id;
    FOR i IN 1..53 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024903', 'Can''t believe how much data we are generating. - 99') RETURNING tweet_id INTO t_id;
    FOR i IN 1..145 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024307', 'Beautiful UI makes a huge difference. - 56') RETURNING tweet_id INTO t_id;
    FOR i IN 1..107 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024475', 'Just deployed the latest update to UniTweet. - 58') RETURNING tweet_id INTO t_id;
    FOR i IN 1..92 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024338', 'Just deployed the latest update to UniTweet. - 56') RETURNING tweet_id INTO t_id;
    FOR i IN 1..77 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024475', 'Just working on the new database project! #CS - 19') RETURNING tweet_id INTO t_id;
    FOR i IN 1..135 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024307', 'Just working on the new database project! #CS - 43') RETURNING tweet_id INTO t_id;
    FOR i IN 1..63 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024307', 'Is anyone else struggling with triggers? - 67') RETURNING tweet_id INTO t_id;
    FOR i IN 1..109 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024903', 'Testing the massive synthetic dataset now! - 1') RETURNING tweet_id INTO t_id;
    FOR i IN 1..56 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024903', 'PostgreSQL rocks! - 82') RETURNING tweet_id INTO t_id;
    FOR i IN 1..134 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024338', 'Can''t believe how much data we are generating. - 62') RETURNING tweet_id INTO t_id;
    FOR i IN 1..147 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024903', 'Final year projects are stressful but fun. - 68') RETURNING tweet_id INTO t_id;
    FOR i IN 1..130 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024475', 'Firebase integration was tough but we did it! - 56') RETURNING tweet_id INTO t_id;
    FOR i IN 1..81 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024903', 'Can''t believe how much data we are generating. - 61') RETURNING tweet_id INTO t_id;
    FOR i IN 1..93 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024475', 'PostgreSQL rocks! - 100') RETURNING tweet_id INTO t_id;
    FOR i IN 1..70 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024903', 'PostgreSQL rocks! - 25') RETURNING tweet_id INTO t_id;
    FOR i IN 1..112 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
    INSERT INTO tweets (author_reg_no, content) VALUES ('2024307', 'Firebase integration was tough but we did it! - 93') RETURNING tweet_id INTO t_id;
    FOR i IN 1..113 LOOP
        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;
    END LOOP;
END $$;

-- ==========================================
-- 5. GENERATE NORMAL TWEETS
-- ==========================================
INSERT INTO tweets (author_reg_no, content) VALUES ('2022528', 'This is a random test tweet 1656');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022972', 'This is a random test tweet 114');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022834', 'This is a random test tweet 4023');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022339', 'This is a random test tweet 7326');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022776', 'This is a random test tweet 1110');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022686', 'This is a random test tweet 2006');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022569', 'This is a random test tweet 498');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022140', 'This is a random test tweet 4576');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022636', 'This is a random test tweet 8231');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022635', 'This is a random test tweet 1286');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022155', 'This is a random test tweet 4297');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022011', 'This is a random test tweet 7628');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022118', 'This is a random test tweet 8082');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022100', 'This is a random test tweet 1290');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022861', 'This is a random test tweet 6023');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022316', 'This is a random test tweet 7983');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022191', 'This is a random test tweet 7147');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022140', 'This is a random test tweet 9214');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022406', 'This is a random test tweet 7623');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022683', 'This is a random test tweet 4029');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022514', 'This is a random test tweet 5389');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022470', 'This is a random test tweet 5703');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022029', 'This is a random test tweet 599');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022746', 'This is a random test tweet 5069');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022048', 'This is a random test tweet 4243');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022991', 'This is a random test tweet 1718');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022942', 'This is a random test tweet 2245');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022484', 'This is a random test tweet 9032');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022725', 'This is a random test tweet 1449');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022683', 'This is a random test tweet 8693');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022946', 'This is a random test tweet 9327');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022393', 'This is a random test tweet 1993');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022057', 'This is a random test tweet 7857');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022950', 'This is a random test tweet 2891');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022689', 'This is a random test tweet 127');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022124', 'This is a random test tweet 2824');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022626', 'This is a random test tweet 1184');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022405', 'This is a random test tweet 4365');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022017', 'This is a random test tweet 301');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022078', 'This is a random test tweet 1401');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022465', 'This is a random test tweet 7800');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022116', 'This is a random test tweet 5625');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022763', 'This is a random test tweet 5121');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022683', 'This is a random test tweet 623');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022175', 'This is a random test tweet 1582');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022672', 'This is a random test tweet 4669');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022469', 'This is a random test tweet 7516');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022479', 'This is a random test tweet 4876');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022280', 'This is a random test tweet 2525');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022435', 'This is a random test tweet 8122');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022399', 'This is a random test tweet 8024');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022333', 'This is a random test tweet 8724');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022510', 'This is a random test tweet 7858');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022240', 'This is a random test tweet 2651');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022701', 'This is a random test tweet 7584');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022057', 'This is a random test tweet 5496');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022190', 'This is a random test tweet 1892');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022519', 'This is a random test tweet 5881');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022176', 'This is a random test tweet 2640');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022253', 'This is a random test tweet 5135');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022567', 'This is a random test tweet 6434');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022633', 'This is a random test tweet 8386');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022343', 'This is a random test tweet 5603');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022897', 'This is a random test tweet 8');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022652', 'This is a random test tweet 6469');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022803', 'This is a random test tweet 6059');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022628', 'This is a random test tweet 798');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022218', 'This is a random test tweet 4915');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022771', 'This is a random test tweet 9051');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022950', 'This is a random test tweet 4900');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022318', 'This is a random test tweet 8836');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022448', 'This is a random test tweet 5203');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022269', 'This is a random test tweet 3497');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022402', 'This is a random test tweet 8015');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022077', 'This is a random test tweet 8344');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022281', 'This is a random test tweet 7678');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022748', 'This is a random test tweet 8160');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022960', 'This is a random test tweet 9466');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022661', 'This is a random test tweet 4698');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022789', 'This is a random test tweet 7620');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022413', 'This is a random test tweet 5466');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022789', 'This is a random test tweet 4310');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022589', 'This is a random test tweet 824');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022436', 'This is a random test tweet 6624');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022893', 'This is a random test tweet 8182');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022399', 'This is a random test tweet 9491');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022054', 'This is a random test tweet 8069');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022340', 'This is a random test tweet 3716');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022873', 'This is a random test tweet 8557');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022646', 'This is a random test tweet 3995');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022621', 'This is a random test tweet 6893');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022870', 'This is a random test tweet 5831');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022421', 'This is a random test tweet 1241');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022164', 'This is a random test tweet 3157');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022682', 'This is a random test tweet 7915');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022930', 'This is a random test tweet 7775');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022638', 'This is a random test tweet 5445');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022110', 'This is a random test tweet 4437');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022113', 'This is a random test tweet 1388');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022311', 'This is a random test tweet 8412');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022301', 'This is a random test tweet 3816');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022593', 'This is a random test tweet 6640');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022686', 'This is a random test tweet 8476');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022665', 'This is a random test tweet 8560');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022333', 'This is a random test tweet 334');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022963', 'This is a random test tweet 9112');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022624', 'This is a random test tweet 6108');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022374', 'This is a random test tweet 2525');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022228', 'This is a random test tweet 1068');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022788', 'This is a random test tweet 6855');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022824', 'This is a random test tweet 9022');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022545', 'This is a random test tweet 5151');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022616', 'This is a random test tweet 9252');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022208', 'This is a random test tweet 2916');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022405', 'This is a random test tweet 1953');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022353', 'This is a random test tweet 2733');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022969', 'This is a random test tweet 7083');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022242', 'This is a random test tweet 5733');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022143', 'This is a random test tweet 7493');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022209', 'This is a random test tweet 6025');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022718', 'This is a random test tweet 5023');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022051', 'This is a random test tweet 531');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022961', 'This is a random test tweet 693');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022543', 'This is a random test tweet 316');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022305', 'This is a random test tweet 6678');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022003', 'This is a random test tweet 1183');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022545', 'This is a random test tweet 4100');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022294', 'This is a random test tweet 6745');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022669', 'This is a random test tweet 8150');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022671', 'This is a random test tweet 5500');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022692', 'This is a random test tweet 9906');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022019', 'This is a random test tweet 9898');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022486', 'This is a random test tweet 5644');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022187', 'This is a random test tweet 9834');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022638', 'This is a random test tweet 6225');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022730', 'This is a random test tweet 4742');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022827', 'This is a random test tweet 295');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022320', 'This is a random test tweet 5121');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022896', 'This is a random test tweet 9884');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022076', 'This is a random test tweet 2343');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022298', 'This is a random test tweet 6909');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022489', 'This is a random test tweet 960');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022091', 'This is a random test tweet 8557');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022962', 'This is a random test tweet 1650');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022689', 'This is a random test tweet 9674');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022559', 'This is a random test tweet 7611');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022300', 'This is a random test tweet 2583');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022596', 'This is a random test tweet 4310');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022706', 'This is a random test tweet 5280');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022620', 'This is a random test tweet 3122');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022123', 'This is a random test tweet 1913');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022362', 'This is a random test tweet 2358');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022853', 'This is a random test tweet 5801');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022427', 'This is a random test tweet 2677');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022620', 'This is a random test tweet 8942');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022929', 'This is a random test tweet 3599');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022272', 'This is a random test tweet 2500');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022264', 'This is a random test tweet 7141');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022672', 'This is a random test tweet 3954');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022941', 'This is a random test tweet 3606');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022443', 'This is a random test tweet 8346');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022157', 'This is a random test tweet 3256');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022627', 'This is a random test tweet 4565');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022961', 'This is a random test tweet 7833');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022644', 'This is a random test tweet 1236');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022759', 'This is a random test tweet 5870');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022348', 'This is a random test tweet 1492');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022818', 'This is a random test tweet 2249');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022622', 'This is a random test tweet 5435');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022748', 'This is a random test tweet 2118');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022510', 'This is a random test tweet 4116');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022191', 'This is a random test tweet 1626');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022319', 'This is a random test tweet 4434');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022123', 'This is a random test tweet 8952');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022360', 'This is a random test tweet 9785');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022504', 'This is a random test tweet 6307');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022264', 'This is a random test tweet 1422');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022152', 'This is a random test tweet 4319');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022696', 'This is a random test tweet 7512');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022369', 'This is a random test tweet 1388');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022960', 'This is a random test tweet 7116');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022412', 'This is a random test tweet 1448');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022192', 'This is a random test tweet 5874');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022363', 'This is a random test tweet 8248');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022833', 'This is a random test tweet 807');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022637', 'This is a random test tweet 9241');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022478', 'This is a random test tweet 9764');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022974', 'This is a random test tweet 30');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022546', 'This is a random test tweet 6548');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022062', 'This is a random test tweet 2188');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022362', 'This is a random test tweet 6570');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022174', 'This is a random test tweet 3081');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022117', 'This is a random test tweet 8490');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022769', 'This is a random test tweet 2717');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022266', 'This is a random test tweet 5122');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022992', 'This is a random test tweet 9020');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022212', 'This is a random test tweet 3461');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022528', 'This is a random test tweet 9333');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022214', 'This is a random test tweet 8351');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022117', 'This is a random test tweet 2998');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022131', 'This is a random test tweet 9740');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022221', 'This is a random test tweet 9062');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022363', 'This is a random test tweet 7504');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022241', 'This is a random test tweet 9117');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022325', 'This is a random test tweet 917');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022175', 'This is a random test tweet 5904');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022368', 'This is a random test tweet 3775');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022643', 'This is a random test tweet 3540');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022465', 'This is a random test tweet 5764');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022039', 'This is a random test tweet 8923');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022135', 'This is a random test tweet 1030');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022274', 'This is a random test tweet 911');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022313', 'This is a random test tweet 8957');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022160', 'This is a random test tweet 4898');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022464', 'This is a random test tweet 3323');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022645', 'This is a random test tweet 2899');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022449', 'This is a random test tweet 1368');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022415', 'This is a random test tweet 8528');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022606', 'This is a random test tweet 4153');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022512', 'This is a random test tweet 7897');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022125', 'This is a random test tweet 3717');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022675', 'This is a random test tweet 7195');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022423', 'This is a random test tweet 7411');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022949', 'This is a random test tweet 3714');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022474', 'This is a random test tweet 190');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022796', 'This is a random test tweet 5430');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022007', 'This is a random test tweet 6911');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022278', 'This is a random test tweet 2814');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022140', 'This is a random test tweet 6966');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022565', 'This is a random test tweet 1843');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022092', 'This is a random test tweet 7356');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022432', 'This is a random test tweet 1959');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022096', 'This is a random test tweet 4319');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022657', 'This is a random test tweet 7009');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022659', 'This is a random test tweet 9606');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022614', 'This is a random test tweet 6879');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022559', 'This is a random test tweet 4515');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022245', 'This is a random test tweet 3867');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022422', 'This is a random test tweet 7970');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022035', 'This is a random test tweet 580');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022093', 'This is a random test tweet 7597');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022400', 'This is a random test tweet 7942');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022961', 'This is a random test tweet 2689');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022300', 'This is a random test tweet 3612');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022659', 'This is a random test tweet 6205');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022872', 'This is a random test tweet 3724');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022166', 'This is a random test tweet 4236');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022139', 'This is a random test tweet 9791');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022560', 'This is a random test tweet 3055');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022494', 'This is a random test tweet 9720');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022033', 'This is a random test tweet 9743');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022027', 'This is a random test tweet 7102');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022726', 'This is a random test tweet 1394');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022260', 'This is a random test tweet 5585');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022427', 'This is a random test tweet 4043');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022626', 'This is a random test tweet 3594');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022595', 'This is a random test tweet 9979');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022270', 'This is a random test tweet 1834');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022803', 'This is a random test tweet 8637');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022814', 'This is a random test tweet 2166');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022098', 'This is a random test tweet 8737');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022027', 'This is a random test tweet 1311');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022078', 'This is a random test tweet 2200');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022657', 'This is a random test tweet 5488');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022560', 'This is a random test tweet 3139');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022625', 'This is a random test tweet 8144');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022710', 'This is a random test tweet 6462');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022372', 'This is a random test tweet 3763');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022440', 'This is a random test tweet 9326');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022892', 'This is a random test tweet 9484');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022066', 'This is a random test tweet 7784');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022136', 'This is a random test tweet 7756');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022536', 'This is a random test tweet 4821');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022980', 'This is a random test tweet 3070');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022536', 'This is a random test tweet 9649');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022587', 'This is a random test tweet 7867');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022628', 'This is a random test tweet 1700');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022393', 'This is a random test tweet 2273');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022607', 'This is a random test tweet 8149');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022998', 'This is a random test tweet 4939');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022112', 'This is a random test tweet 1653');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022910', 'This is a random test tweet 7600');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022152', 'This is a random test tweet 6436');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022170', 'This is a random test tweet 3850');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022350', 'This is a random test tweet 2644');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022795', 'This is a random test tweet 8784');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022299', 'This is a random test tweet 3955');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022898', 'This is a random test tweet 8371');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022861', 'This is a random test tweet 3858');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022022', 'This is a random test tweet 5648');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022945', 'This is a random test tweet 3370');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022886', 'This is a random test tweet 5380');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022406', 'This is a random test tweet 4937');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022346', 'This is a random test tweet 5087');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022771', 'This is a random test tweet 3984');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022617', 'This is a random test tweet 2437');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022210', 'This is a random test tweet 8550');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022394', 'This is a random test tweet 5187');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022865', 'This is a random test tweet 672');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022015', 'This is a random test tweet 5400');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022819', 'This is a random test tweet 6286');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022110', 'This is a random test tweet 1084');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022688', 'This is a random test tweet 5845');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022754', 'This is a random test tweet 5336');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022109', 'This is a random test tweet 8936');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022370', 'This is a random test tweet 6881');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022142', 'This is a random test tweet 860');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022111', 'This is a random test tweet 2040');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022199', 'This is a random test tweet 1182');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022508', 'This is a random test tweet 148');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022608', 'This is a random test tweet 7932');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022503', 'This is a random test tweet 2207');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022000', 'This is a random test tweet 7748');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022462', 'This is a random test tweet 7199');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022346', 'This is a random test tweet 8289');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022696', 'This is a random test tweet 5869');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022794', 'This is a random test tweet 1745');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022724', 'This is a random test tweet 2796');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022116', 'This is a random test tweet 4176');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022734', 'This is a random test tweet 1753');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022190', 'This is a random test tweet 5147');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022440', 'This is a random test tweet 1853');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022898', 'This is a random test tweet 8937');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022962', 'This is a random test tweet 8981');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022489', 'This is a random test tweet 7919');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022540', 'This is a random test tweet 3519');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022932', 'This is a random test tweet 9432');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022734', 'This is a random test tweet 4960');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022298', 'This is a random test tweet 4084');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022590', 'This is a random test tweet 6780');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022181', 'This is a random test tweet 5661');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022175', 'This is a random test tweet 9094');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022459', 'This is a random test tweet 3927');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022269', 'This is a random test tweet 3078');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022685', 'This is a random test tweet 3259');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022385', 'This is a random test tweet 3697');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022633', 'This is a random test tweet 3740');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022659', 'This is a random test tweet 9192');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022332', 'This is a random test tweet 800');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022126', 'This is a random test tweet 3147');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022837', 'This is a random test tweet 1351');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022592', 'This is a random test tweet 8814');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022246', 'This is a random test tweet 8448');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022569', 'This is a random test tweet 6428');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022129', 'This is a random test tweet 5898');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022499', 'This is a random test tweet 9930');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022363', 'This is a random test tweet 7382');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022497', 'This is a random test tweet 6517');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022287', 'This is a random test tweet 2790');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022654', 'This is a random test tweet 8972');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022459', 'This is a random test tweet 3866');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022507', 'This is a random test tweet 7757');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022116', 'This is a random test tweet 8678');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022002', 'This is a random test tweet 3306');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022201', 'This is a random test tweet 7645');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022752', 'This is a random test tweet 6483');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022515', 'This is a random test tweet 7662');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022456', 'This is a random test tweet 5345');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022019', 'This is a random test tweet 1209');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022431', 'This is a random test tweet 6199');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022817', 'This is a random test tweet 4062');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022742', 'This is a random test tweet 8730');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022111', 'This is a random test tweet 9304');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022743', 'This is a random test tweet 3936');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022112', 'This is a random test tweet 9458');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022601', 'This is a random test tweet 3058');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022446', 'This is a random test tweet 9438');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022567', 'This is a random test tweet 2325');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022158', 'This is a random test tweet 639');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022588', 'This is a random test tweet 5035');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022255', 'This is a random test tweet 1675');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022955', 'This is a random test tweet 7773');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022545', 'This is a random test tweet 7227');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022649', 'This is a random test tweet 1206');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022120', 'This is a random test tweet 1506');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022191', 'This is a random test tweet 5014');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022973', 'This is a random test tweet 9018');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022110', 'This is a random test tweet 6569');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022875', 'This is a random test tweet 666');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022541', 'This is a random test tweet 4494');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022582', 'This is a random test tweet 2920');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022524', 'This is a random test tweet 1205');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022590', 'This is a random test tweet 8019');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022810', 'This is a random test tweet 7735');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022974', 'This is a random test tweet 9708');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022798', 'This is a random test tweet 2294');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022894', 'This is a random test tweet 3926');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022435', 'This is a random test tweet 8617');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022945', 'This is a random test tweet 4784');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022453', 'This is a random test tweet 8764');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022476', 'This is a random test tweet 9773');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022982', 'This is a random test tweet 4263');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022415', 'This is a random test tweet 4601');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022388', 'This is a random test tweet 3083');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022840', 'This is a random test tweet 5219');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022578', 'This is a random test tweet 4691');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022733', 'This is a random test tweet 7179');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022489', 'This is a random test tweet 2778');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022786', 'This is a random test tweet 7487');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022191', 'This is a random test tweet 5273');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022870', 'This is a random test tweet 8047');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022352', 'This is a random test tweet 6996');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022610', 'This is a random test tweet 3522');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022583', 'This is a random test tweet 2556');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022227', 'This is a random test tweet 7877');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022384', 'This is a random test tweet 2289');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022930', 'This is a random test tweet 2066');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022085', 'This is a random test tweet 9355');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022812', 'This is a random test tweet 8288');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022883', 'This is a random test tweet 9255');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022445', 'This is a random test tweet 8552');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022608', 'This is a random test tweet 1854');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022096', 'This is a random test tweet 9932');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022575', 'This is a random test tweet 9476');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022845', 'This is a random test tweet 8545');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022060', 'This is a random test tweet 3080');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022051', 'This is a random test tweet 3729');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022908', 'This is a random test tweet 9542');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022250', 'This is a random test tweet 3799');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022138', 'This is a random test tweet 7438');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022424', 'This is a random test tweet 9556');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022174', 'This is a random test tweet 2811');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022021', 'This is a random test tweet 260');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022744', 'This is a random test tweet 841');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022147', 'This is a random test tweet 6343');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022585', 'This is a random test tweet 5828');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022051', 'This is a random test tweet 3');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022482', 'This is a random test tweet 4806');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022430', 'This is a random test tweet 6955');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022962', 'This is a random test tweet 9191');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022239', 'This is a random test tweet 2247');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022706', 'This is a random test tweet 9910');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022722', 'This is a random test tweet 818');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022148', 'This is a random test tweet 1182');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022537', 'This is a random test tweet 9964');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022034', 'This is a random test tweet 2582');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022748', 'This is a random test tweet 2972');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022241', 'This is a random test tweet 3925');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022013', 'This is a random test tweet 7260');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022682', 'This is a random test tweet 1445');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022541', 'This is a random test tweet 9329');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022707', 'This is a random test tweet 7395');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022968', 'This is a random test tweet 8379');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022575', 'This is a random test tweet 5764');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022732', 'This is a random test tweet 6129');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022698', 'This is a random test tweet 7115');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022886', 'This is a random test tweet 3331');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022884', 'This is a random test tweet 5618');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022339', 'This is a random test tweet 662');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022678', 'This is a random test tweet 1837');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022053', 'This is a random test tweet 6840');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022870', 'This is a random test tweet 7022');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022378', 'This is a random test tweet 9049');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022835', 'This is a random test tweet 9351');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022285', 'This is a random test tweet 4659');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022664', 'This is a random test tweet 2727');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022502', 'This is a random test tweet 6544');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022319', 'This is a random test tweet 2890');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022975', 'This is a random test tweet 7303');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022667', 'This is a random test tweet 1548');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022678', 'This is a random test tweet 8742');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022228', 'This is a random test tweet 1894');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022746', 'This is a random test tweet 312');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022286', 'This is a random test tweet 9441');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022434', 'This is a random test tweet 5588');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022288', 'This is a random test tweet 507');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022507', 'This is a random test tweet 6404');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022851', 'This is a random test tweet 957');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022874', 'This is a random test tweet 4741');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022289', 'This is a random test tweet 4860');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022217', 'This is a random test tweet 8602');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022526', 'This is a random test tweet 5773');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022238', 'This is a random test tweet 6818');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022699', 'This is a random test tweet 821');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022047', 'This is a random test tweet 1063');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022698', 'This is a random test tweet 9270');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022710', 'This is a random test tweet 1339');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022092', 'This is a random test tweet 5903');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022019', 'This is a random test tweet 3344');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022257', 'This is a random test tweet 1155');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022415', 'This is a random test tweet 6669');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022530', 'This is a random test tweet 6325');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022525', 'This is a random test tweet 3366');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022253', 'This is a random test tweet 6134');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022681', 'This is a random test tweet 8711');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022509', 'This is a random test tweet 7441');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022107', 'This is a random test tweet 3880');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022245', 'This is a random test tweet 1594');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022014', 'This is a random test tweet 4473');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022706', 'This is a random test tweet 1195');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022265', 'This is a random test tweet 5798');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022482', 'This is a random test tweet 2208');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022673', 'This is a random test tweet 5002');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022034', 'This is a random test tweet 4608');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022159', 'This is a random test tweet 6300');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022507', 'This is a random test tweet 7302');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022442', 'This is a random test tweet 5102');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022721', 'This is a random test tweet 7025');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022200', 'This is a random test tweet 9223');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022126', 'This is a random test tweet 9723');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022668', 'This is a random test tweet 2746');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022204', 'This is a random test tweet 120');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022579', 'This is a random test tweet 5106');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022273', 'This is a random test tweet 5904');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022970', 'This is a random test tweet 2168');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022020', 'This is a random test tweet 7755');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022169', 'This is a random test tweet 9630');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022341', 'This is a random test tweet 5534');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022057', 'This is a random test tweet 7640');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022998', 'This is a random test tweet 2936');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022333', 'This is a random test tweet 857');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022708', 'This is a random test tweet 109');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022189', 'This is a random test tweet 8637');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022559', 'This is a random test tweet 8905');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022261', 'This is a random test tweet 3501');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022332', 'This is a random test tweet 2286');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022730', 'This is a random test tweet 122');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022996', 'This is a random test tweet 1160');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022208', 'This is a random test tweet 7767');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022444', 'This is a random test tweet 3096');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022434', 'This is a random test tweet 7644');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022238', 'This is a random test tweet 1617');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022900', 'This is a random test tweet 1150');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022239', 'This is a random test tweet 3941');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022942', 'This is a random test tweet 1591');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022510', 'This is a random test tweet 9405');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022614', 'This is a random test tweet 1210');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022754', 'This is a random test tweet 3960');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022841', 'This is a random test tweet 3595');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022275', 'This is a random test tweet 3879');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022195', 'This is a random test tweet 7776');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022079', 'This is a random test tweet 2698');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022605', 'This is a random test tweet 8448');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022606', 'This is a random test tweet 6874');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022780', 'This is a random test tweet 9471');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022277', 'This is a random test tweet 1727');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022762', 'This is a random test tweet 6594');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022119', 'This is a random test tweet 8671');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022654', 'This is a random test tweet 2423');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022467', 'This is a random test tweet 2239');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022783', 'This is a random test tweet 8968');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022005', 'This is a random test tweet 7465');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022628', 'This is a random test tweet 1017');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022224', 'This is a random test tweet 134');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022626', 'This is a random test tweet 7215');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022013', 'This is a random test tweet 7859');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022817', 'This is a random test tweet 8916');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022208', 'This is a random test tweet 2927');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022789', 'This is a random test tweet 2557');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022500', 'This is a random test tweet 5137');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022568', 'This is a random test tweet 4708');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022696', 'This is a random test tweet 6573');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022033', 'This is a random test tweet 3166');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022386', 'This is a random test tweet 1159');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022600', 'This is a random test tweet 3386');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022382', 'This is a random test tweet 7524');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022405', 'This is a random test tweet 5339');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022732', 'This is a random test tweet 8188');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022051', 'This is a random test tweet 8153');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022283', 'This is a random test tweet 7032');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022414', 'This is a random test tweet 2191');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022641', 'This is a random test tweet 7491');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022561', 'This is a random test tweet 1259');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022154', 'This is a random test tweet 8345');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022520', 'This is a random test tweet 7842');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022327', 'This is a random test tweet 3361');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022691', 'This is a random test tweet 4168');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022017', 'This is a random test tweet 4472');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022744', 'This is a random test tweet 624');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022041', 'This is a random test tweet 1268');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022597', 'This is a random test tweet 1660');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022968', 'This is a random test tweet 9966');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022511', 'This is a random test tweet 4667');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022573', 'This is a random test tweet 702');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022505', 'This is a random test tweet 850');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022076', 'This is a random test tweet 5039');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022352', 'This is a random test tweet 9936');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022002', 'This is a random test tweet 9498');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022973', 'This is a random test tweet 4947');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022564', 'This is a random test tweet 2225');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022922', 'This is a random test tweet 3199');
INSERT INTO tweets (author_reg_no, content) VALUES ('2022398', 'This is a random test tweet 1775');


-- 6. GENERATE INBOX MESSAGES

INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024338', '2022934', 'Hello from 2024338!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022934', '2024338', 'Hi 2024338, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024307', '2022336', 'Hello from 2024307!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022336', '2024307', 'Hi 2024307, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024338', '2022549', 'Hello from 2024338!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022549', '2024338', 'Hi 2024338, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024338', '2022768', 'Hello from 2024338!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022768', '2024338', 'Hi 2024338, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024903', '2022150', 'Hello from 2024903!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022150', '2024903', 'Hi 2024903, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024475', '2022777', 'Hello from 2024475!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022777', '2024475', 'Hi 2024475, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024475', '2022744', 'Hello from 2024475!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022744', '2024475', 'Hi 2024475, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024307', '2022340', 'Hello from 2024307!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022340', '2024307', 'Hi 2024307, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024338', '2022617', 'Hello from 2024338!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022617', '2024338', 'Hi 2024338, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024338', '2022233', 'Hello from 2024338!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022233', '2024338', 'Hi 2024338, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024475', '2022918', 'Hello from 2024475!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022918', '2024475', 'Hi 2024475, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024307', '2022368', 'Hello from 2024307!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022368', '2024307', 'Hi 2024307, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024307', '2022329', 'Hello from 2024307!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022329', '2024307', 'Hi 2024307, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024307', '2022294', 'Hello from 2024307!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022294', '2024307', 'Hi 2024307, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024338', '2022608', 'Hello from 2024338!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022608', '2024338', 'Hi 2024338, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024307', '2022720', 'Hello from 2024307!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022720', '2024307', 'Hi 2024307, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024338', '2022300', 'Hello from 2024338!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022300', '2024338', 'Hi 2024338, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024338', '2022777', 'Hello from 2024338!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022777', '2024338', 'Hi 2024338, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024475', '2022558', 'Hello from 2024475!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022558', '2024475', 'Hi 2024475, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024903', '2022184', 'Hello from 2024903!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022184', '2024903', 'Hi 2024903, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024338', '2022882', 'Hello from 2024338!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022882', '2024338', 'Hi 2024338, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024338', '2022662', 'Hello from 2024338!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022662', '2024338', 'Hi 2024338, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024475', '2022532', 'Hello from 2024475!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022532', '2024475', 'Hi 2024475, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024903', '2022660', 'Hello from 2024903!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022660', '2024903', 'Hi 2024903, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024338', '2022217', 'Hello from 2024338!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022217', '2024338', 'Hi 2024338, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024307', '2022293', 'Hello from 2024307!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022293', '2024307', 'Hi 2024307, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024338', '2022461', 'Hello from 2024338!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022461', '2024338', 'Hi 2024338, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024338', '2022172', 'Hello from 2024338!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022172', '2024338', 'Hi 2024338, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024475', '2022897', 'Hello from 2024475!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022897', '2024475', 'Hi 2024475, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024307', '2022145', 'Hello from 2024307!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022145', '2024307', 'Hi 2024307, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024338', '2022879', 'Hello from 2024338!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022879', '2024338', 'Hi 2024338, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024475', '2022248', 'Hello from 2024475!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022248', '2024475', 'Hi 2024475, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024338', '2022424', 'Hello from 2024338!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022424', '2024338', 'Hi 2024338, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024307', '2022353', 'Hello from 2024307!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022353', '2024307', 'Hi 2024307, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024903', '2022724', 'Hello from 2024903!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022724', '2024903', 'Hi 2024903, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024338', '2022648', 'Hello from 2024338!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022648', '2024338', 'Hi 2024338, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024475', '2022780', 'Hello from 2024475!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022780', '2024475', 'Hi 2024475, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024475', '2022190', 'Hello from 2024475!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022190', '2024475', 'Hi 2024475, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024307', '2022757', 'Hello from 2024307!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022757', '2024307', 'Hi 2024307, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024475', '2022309', 'Hello from 2024475!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022309', '2024475', 'Hi 2024475, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024475', '2022116', 'Hello from 2024475!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022116', '2024475', 'Hi 2024475, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024338', '2022183', 'Hello from 2024338!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022183', '2024338', 'Hi 2024338, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024338', '2022836', 'Hello from 2024338!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022836', '2024338', 'Hi 2024338, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024307', '2022724', 'Hello from 2024307!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022724', '2024307', 'Hi 2024307, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024475', '2022525', 'Hello from 2024475!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022525', '2024475', 'Hi 2024475, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024475', '2022205', 'Hello from 2024475!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022205', '2024475', 'Hi 2024475, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024307', '2022756', 'Hello from 2024307!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022756', '2024307', 'Hi 2024307, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024903', '2022924', 'Hello from 2024903!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022924', '2024903', 'Hi 2024903, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024475', '2022401', 'Hello from 2024475!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022401', '2024475', 'Hi 2024475, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024903', '2022691', 'Hello from 2024903!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022691', '2024903', 'Hi 2024903, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024307', '2022601', 'Hello from 2024307!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022601', '2024307', 'Hi 2024307, responding to your message.');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2024903', '2022091', 'Hello from 2024903!');
INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('2022091', '2024903', 'Hi 2024903, responding to your message.');


-- GENERATE REPORTS

INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022033', '2022578', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022868', '2022833', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022923', '2022119', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022100', '2022459', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022623', '2022807', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022604', '2022005', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022107', '2022822', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022438', '2022781', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022541', '2022919', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022690', '2022137', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022717', '2022332', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022157', '2022131', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022935', '2022147', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022135', '2022501', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022394', '2022329', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022910', '2022533', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022991', '2022659', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022278', '2022427', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022208', '2022167', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022356', '2022752', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022510', '2022542', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022275', '2022351', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022143', '2022028', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022903', '2022548', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022381', '2022730', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022928', '2022705', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022110', '2022789', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022123', '2022477', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022385', '2022528', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022737', '2022050', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022109', '2022431', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022670', '2022790', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022767', '2022167', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022153', '2022012', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022577', '2022496', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022733', '2022779', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022448', '2022278', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022930', '2022040', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022758', '2022577', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022154', '2022198', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022504', '2022354', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022447', '2022908', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022034', '2022786', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022190', '2022829', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022650', '2022494', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022125', '2022196', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022876', '2022843', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022888', '2022497', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022006', '2022301', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022263', '2022710', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022041', '2022771', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022142', '2022126', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022604', '2022301', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022901', '2022059', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022751', '2022612', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022547', '2022374', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022294', '2022647', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022002', '2022276', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022799', '2022302', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022377', '2022041', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022145', '2022592', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022499', '2022266', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022628', '2022071', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022251', '2022906', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022670', '2022910', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022575', '2022683', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022730', '2022613', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022480', '2022120', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022062', '2022756', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022287', '2022583', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022442', '2022375', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022479', '2022889', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022994', '2022123', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022891', '2022315', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022987', '2022783', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022245', '2022202', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022779', '2022565', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022033', '2022438', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022629', '2022649', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022043', '2022662', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022926', '2022886', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022590', '2022629', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022613', '2022478', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022883', '2022093', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022151', '2022790', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022856', '2022972', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022163', '2022478', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022073', '2022404', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022918', '2022107', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022042', '2022041', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022842', '2022610', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022733', '2022303', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022643', '2022434', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022993', '2022467', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022488', '2022935', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022147', '2022920', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022318', '2022217', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022486', '2022376', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022673', '2022429', 'Spam account', 'PENDING');
INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('2022618', '2022020', 'Spam account', 'PENDING');