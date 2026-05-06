import tkinter as tk
from tkinter import ttk, messagebox, simpledialog
import bcrypt
import db

session = {"user": None, "is_admin": False}

# --- Premium Dark Mode Palette ---
BG_COLOR = "#15202b"
CARD_BG = "#192734"
TEXT_COLOR = "#ffffff"
DIM_TEXT = "#8899a6"
ACCENT = "#1da1f2"
ACCENT_HOVER = "#1a91da"
DANGER = "#e0245e"
SUCCESS = "#17bf63"

# --- Custom Interactive Elements ---
class HoverButton(tk.Button):
    def __init__(self, master, hover_color=ACCENT_HOVER, **kw):
        super().__init__(master, **kw)
        self.default_bg = self["background"]
        self.hover_color = hover_color
        self.bind("<Enter>", self.on_enter)
        self.bind("<Leave>", self.on_leave)

    def on_enter(self, e):
        self['background'] = self.hover_color

    def on_leave(self, e):
        self['background'] = self.default_bg

class UniTweetApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("UniTweet")
        self.geometry("1100x800")
        self.configure(bg=BG_COLOR)

        self.style = ttk.Style(self)
        self.style.theme_use('clam')
        
        # Configure Styles
        self.style.configure("TFrame", background=BG_COLOR)
        self.style.configure("Card.TFrame", background=CARD_BG)
        
        # Label Styles
        self.style.configure("TLabel", background=BG_COLOR, foreground=TEXT_COLOR, font=("Segoe UI", 11))
        self.style.configure("Title.TLabel", font=("Segoe UI", 28, "bold"), foreground=ACCENT)
        self.style.configure("Header.TLabel", font=("Segoe UI", 20, "bold"))
        self.style.configure("Card.TLabel", background=CARD_BG, foreground=TEXT_COLOR, font=("Segoe UI", 12))
        self.style.configure("DimCard.TLabel", background=CARD_BG, foreground=DIM_TEXT, font=("Segoe UI", 10))
        self.style.configure("BoldCard.TLabel", background=CARD_BG, foreground=TEXT_COLOR, font=("Segoe UI", 12, "bold"))

        # Entry/Combobox Styles
        self.style.configure("TEntry", fieldbackground=CARD_BG, foreground=TEXT_COLOR, borderwidth=0, padding=10)
        self.style.configure("TCombobox", fieldbackground=CARD_BG, foreground=TEXT_COLOR, padding=5)

        # App Layout Setup
        self.grid_rowconfigure(0, weight=1)
        self.grid_columnconfigure(1, weight=1)

        # Left Sidebar (Hidden on Login/Register)
        self.sidebar = tk.Frame(self, bg=CARD_BG, width=250)
        self.sidebar.pack_propagate(False)

        # Main Content Area
        self.container = tk.Frame(self, bg=BG_COLOR)
        self.container.grid(row=0, column=1, sticky="nsew")
        self.container.grid_rowconfigure(0, weight=1)
        self.container.grid_columnconfigure(0, weight=1)

        self.frames = {}
        for F in (LoginScreen, RegisterScreen, HomeFeedScreen, TrendingFeedScreen, 
                  ComposeTweetScreen, ProfileScreen, TweetDetailScreen, SearchScreen, 
                  InboxScreen, ConversationScreen, AdminScreen):
            frame = F(self.container, self)
            self.frames[F] = frame
            frame.grid(row=0, column=0, sticky="nsew")

        self.show_frame(LoginScreen)

    def show_frame(self, cont, **kwargs):
        frame = self.frames[cont]
        if hasattr(frame, "on_show"):
            frame.on_show(**kwargs)
        
        frame.tkraise()

        if cont in (LoginScreen, RegisterScreen):
            self.sidebar.grid_forget()
        else:
            self.show_sidebar()

    def show_sidebar(self):
        self.sidebar.grid(row=0, column=0, sticky="nsew")
        for widget in self.sidebar.winfo_children():
            widget.destroy()

        # Logo/Brand
        tk.Label(self.sidebar, text="UniTweet", bg=CARD_BG, fg=ACCENT, font=("Segoe UI", 24, "bold")).pack(pady=40, padx=20, anchor="w")

        nav_links = [
            ("🏠 Home", lambda: self.show_frame(HomeFeedScreen)),
            ("🔥 Trending", lambda: self.show_frame(TrendingFeedScreen)),
            ("🔍 Search", lambda: self.show_frame(SearchScreen)),
            ("✉️ Inbox", lambda: self.show_frame(InboxScreen)),
            ("👤 Profile", lambda: self.show_frame(ProfileScreen, target_id=session["user"]["reg_no"])),
            ("✍️ Post", lambda: self.show_frame(ComposeTweetScreen))
        ]

        for text, cmd in nav_links:
            HoverButton(self.sidebar, text=text, command=cmd, bg=CARD_BG, fg=TEXT_COLOR, 
                        activebackground="#22303c", hover_color="#22303c",
                        font=("Segoe UI", 16, "bold"), relief="flat", anchor="w", padx=20, pady=15, cursor="hand2").pack(fill="x")

        if session.get("is_admin"):
            HoverButton(self.sidebar, text="🛡️ Admin", command=lambda: self.show_frame(AdminScreen), 
                        bg=CARD_BG, fg=DANGER, activebackground="#4a1525", hover_color="#4a1525",
                        font=("Segoe UI", 16, "bold"), relief="flat", anchor="w", padx=20, pady=15, cursor="hand2").pack(fill="x", pady=10)

        # Logout at bottom
        HoverButton(self.sidebar, text="Log out", command=self.logout, bg=CARD_BG, fg=DIM_TEXT, 
                    activebackground="#22303c", hover_color="#22303c",
                    font=("Segoe UI", 14), relief="flat", anchor="w", padx=20, pady=15, cursor="hand2").pack(side="bottom", fill="x", pady=30)

    def logout(self):
        session["user"] = None
        session["is_admin"] = False
        self.show_frame(LoginScreen)


# --- Helper to create a Scrollable Frame area ---
class ScrollableFrame(tk.Frame):
    def __init__(self, container, *args, **kwargs):
        super().__init__(container, bg=BG_COLOR, *args, **kwargs)
        canvas = tk.Canvas(self, bg=BG_COLOR, highlightthickness=0)
        scrollbar = ttk.Scrollbar(self, orient="vertical", command=canvas.yview)
        self.scrollable_frame = tk.Frame(canvas, bg=BG_COLOR)

        self.scrollable_frame.bind(
            "<Configure>",
            lambda e: canvas.configure(scrollregion=canvas.bbox("all"))
        )
        # Bind mousewheel scrolling
        canvas.bind_all("<MouseWheel>", lambda e: canvas.yview_scroll(int(-1*(e.delta/120)), "units"))

        canvas.create_window((0, 0), window=self.scrollable_frame, anchor="nw", width=800)
        canvas.configure(yscrollcommand=scrollbar.set)

        canvas.pack(side="left", fill="both", expand=True)
        scrollbar.pack(side="right", fill="y")


class LoginScreen(tk.Frame):
    def __init__(self, parent, controller):
        super().__init__(parent, bg=BG_COLOR)
        self.controller = controller

        # Center content box
        box = tk.Frame(self, bg=CARD_BG, padx=40, pady=40)
        box.place(relx=0.5, rely=0.5, anchor="center")

        ttk.Label(box, text="UniTweet", style="Title.TLabel").pack(pady=(0, 30))

        ttk.Label(box, text="Email or Registration No", background=CARD_BG).pack(anchor="w")
        self.ident_entry = ttk.Entry(box, width=40, font=("Segoe UI", 12))
        self.ident_entry.pack(pady=(5, 20), ipady=5)

        ttk.Label(box, text="Password", background=CARD_BG).pack(anchor="w")
        self.pass_entry = ttk.Entry(box, width=40, show="*", font=("Segoe UI", 12))
        self.pass_entry.pack(pady=(5, 30), ipady=5)

        HoverButton(box, text="Log in", command=self.login, bg=ACCENT, fg=TEXT_COLOR, 
                    activebackground=ACCENT_HOVER, hover_color=ACCENT_HOVER,
                    font=("Segoe UI", 14, "bold"), relief="flat", cursor="hand2").pack(fill="x", ipady=8)

        HoverButton(box, text="Don't have an account? Sign up", command=lambda: controller.show_frame(RegisterScreen), 
                    bg=CARD_BG, fg=ACCENT, activebackground=CARD_BG, hover_color=CARD_BG,
                    font=("Segoe UI", 11), relief="flat", cursor="hand2").pack(pady=(20, 0))

    def on_show(self):
        self.ident_entry.delete(0, tk.END)
        self.pass_entry.delete(0, tk.END)

    def login(self):
        ident = self.ident_entry.get().strip()
        pwd = self.pass_entry.get()

        if ident == "admin" and pwd == "admin":
            session["user"] = {"reg_no": "ADMIN", "full_name": "System Admin"}
            session["is_admin"] = True
            self.controller.show_frame(AdminScreen)
            return

        user = db.get_user_for_login(ident)
        if user and bcrypt.checkpw(pwd.encode('utf-8'), user['password_hash'].encode('utf-8')):
            session["user"] = user
            session["is_admin"] = False
            self.controller.show_frame(HomeFeedScreen)
        else:
            messagebox.showerror("Error", "Invalid credentials.")

class RegisterScreen(tk.Frame):
    def __init__(self, parent, controller):
        super().__init__(parent, bg=BG_COLOR)
        self.controller = controller

        box = tk.Frame(self, bg=CARD_BG, padx=40, pady=30)
        box.place(relx=0.5, rely=0.5, anchor="center")

        ttk.Label(box, text="Join UniTweet", style="Title.TLabel").pack(pady=(0, 20))

        self.fields = {}
        fields_data = [("Reg No (e.g. 24L-0941):", "reg_no"), ("Full Name:", "full_name"), 
                       ("Email:", "email"), ("Password:", "password"), ("Batch Year:", "batch_year")]

        for label, key in fields_data:
            ttk.Label(box, text=label, background=CARD_BG).pack(anchor="w")
            e = ttk.Entry(box, width=40, show="*" if key == "password" else "", font=("Segoe UI", 11))
            e.pack(pady=(2, 10), ipady=3)
            self.fields[key] = e

        ttk.Label(box, text="Department:", background=CARD_BG).pack(anchor="w")
        self.dept_combo = ttk.Combobox(box, values=["CS", "SE", "AI", "DS", "CY"], state="readonly", font=("Segoe UI", 11))
        self.dept_combo.pack(fill="x", pady=(2, 20), ipady=3)

        HoverButton(box, text="Sign up", command=self.register, bg=ACCENT, fg=TEXT_COLOR, 
                    activebackground=ACCENT_HOVER, hover_color=ACCENT_HOVER,
                    font=("Segoe UI", 14, "bold"), relief="flat", cursor="hand2").pack(fill="x", ipady=5)

        HoverButton(box, text="Already have an account? Log in", command=lambda: controller.show_frame(LoginScreen), 
                    bg=CARD_BG, fg=ACCENT, activebackground=CARD_BG, hover_color=CARD_BG,
                    font=("Segoe UI", 11), relief="flat", cursor="hand2").pack(pady=(15, 0))

    def register(self):
        try:
            reg_no = self.fields["reg_no"].get().strip()
            full_name = self.fields["full_name"].get().strip()
            email = self.fields["email"].get().strip()
            pwd = self.fields["password"].get()
            b_year = int(self.fields["batch_year"].get().strip())
            dept = self.dept_combo.get()

            hashed = bcrypt.hashpw(pwd.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')
            db.register_user(reg_no, full_name, email, hashed, b_year, dept)
            messagebox.showinfo("Success", "Registered! You can now log in.")
            self.controller.show_frame(LoginScreen)
        except Exception as e:
            messagebox.showerror("Error", "Please fill all fields correctly.")

class FeedBaseScreen(tk.Frame):
    """Base class for Home and Trending feeds to reuse rendering logic."""
    def __init__(self, parent, controller, title):
        super().__init__(parent, bg=BG_COLOR)
        self.controller = controller
        
        top = tk.Frame(self, bg=BG_COLOR)
        top.pack(fill="x", padx=20, pady=20)
        ttk.Label(top, text=title, style="Header.TLabel").pack(side="left")

        self.scroll = ScrollableFrame(self)
        self.scroll.pack(fill="both", expand=True, padx=20)

    def render_tweets(self, tweets, clear=True):
        if clear:
            for widget in self.scroll.scrollable_frame.winfo_children():
                widget.destroy()

        if not tweets:
            ttk.Label(self.scroll.scrollable_frame, text="Nothing to see here yet.", font=("Segoe UI", 14), foreground=DIM_TEXT).pack(pady=40)
            return

        for t in tweets:
            card = tk.Frame(self.scroll.scrollable_frame, bg=CARD_BG, pady=15, padx=20)
            card.pack(fill="x", pady=8)
            
            # Header
            header = tk.Frame(card, bg=CARD_BG)
            header.pack(fill="x")
            
            # Author click goes to profile
            btn_author = HoverButton(header, text=t['full_name'], font=("Segoe UI", 14, "bold"), 
                                     bg=CARD_BG, fg=TEXT_COLOR, activebackground=CARD_BG, hover_color=CARD_BG, relief="flat", cursor="hand2",
                                     command=lambda r=t['reg_no']: self.controller.show_frame(ProfileScreen, target_id=r))
            btn_author.pack(side="left")
            ttk.Label(header, text=f" @{t['reg_no']} · {t['created_at'].strftime('%b %d')}", style="DimCard.TLabel").pack(side="left", padx=5)

            # Content
            ttk.Label(card, text=t['content'], style="Card.TLabel", wraplength=700).pack(fill="x", pady=(10, 15), anchor="w")

            # Actions
            actions = tk.Frame(card, bg=CARD_BG)
            actions.pack(fill="x")

            HoverButton(actions, text=f"♥  {t['like_count']}", command=lambda tid=t['tweet_id']: self.toggle_like(tid), 
                        bg=CARD_BG, fg=DIM_TEXT, hover_color=DANGER, font=("Segoe UI", 11), relief="flat", cursor="hand2").pack(side="left", padx=(0, 40))
            
            HoverButton(actions, text=f"💬  {t['reply_count']}", command=lambda tid=t['tweet_id']: self.controller.show_frame(TweetDetailScreen, tweet_id=tid), 
                        bg=CARD_BG, fg=DIM_TEXT, hover_color=ACCENT, font=("Segoe UI", 11), relief="flat", cursor="hand2").pack(side="left")

            HoverButton(actions, text="🚩 Report", command=lambda tid=t['tweet_id']: self.report(tid), 
                        bg=CARD_BG, fg=DIM_TEXT, hover_color=DANGER, font=("Segoe UI", 10), relief="flat", cursor="hand2").pack(side="right")

    def toggle_like(self, tweet_id):
        if session.get("is_admin"):
            messagebox.showerror("Admin", "Admins cannot like tweets.")
            return
        db.toggle_like(tweet_id, session["user"]["reg_no"])
        self.on_show()

    def report(self, tweet_id):
        reason = simpledialog.askstring("Report Tweet", "Reason for reporting:")
        if reason:
            db.create_report(session["user"]["reg_no"], "TWEET", str(tweet_id), reason)
            messagebox.showinfo("Reported", "Report has been submitted for review.")


class HomeFeedScreen(FeedBaseScreen):
    def __init__(self, parent, controller):
        super().__init__(parent, controller, "Home")

    def on_show(self):
        tweets = db.get_home_feed(session["user"]["reg_no"], 0, 50)
        self.render_tweets(tweets)

class TrendingFeedScreen(FeedBaseScreen):
    def __init__(self, parent, controller):
        super().__init__(parent, controller, "Trending Now")

    def on_show(self):
        tweets = db.get_trending_feed(0, 50)
        self.render_tweets(tweets)


class ComposeTweetScreen(tk.Frame):
    def __init__(self, parent, controller):
        super().__init__(parent, bg=BG_COLOR)
        self.controller = controller
        
        ttk.Label(self, text="What's happening?", style="Header.TLabel").pack(pady=(30, 10), padx=30, anchor="w")

        # Text Box with proper styling
        self.textbox = tk.Text(self, bg=CARD_BG, fg=TEXT_COLOR, insertbackground=TEXT_COLOR, 
                               font=("Segoe UI", 16), relief="flat", height=6, wrap="word", padx=15, pady=15)
        self.textbox.pack(fill="x", padx=30)
        self.textbox.bind('<KeyRelease>', self.update_count)

        bot = tk.Frame(self, bg=BG_COLOR)
        bot.pack(fill="x", padx=30, pady=15)

        self.count_lbl = ttk.Label(bot, text="280 remaining", font=("Segoe UI", 11), foreground=DIM_TEXT)
        self.count_lbl.pack(side="left")

        HoverButton(bot, text="Post Tweet", command=self.post, bg=ACCENT, fg=TEXT_COLOR, 
                    activebackground=ACCENT_HOVER, hover_color=ACCENT_HOVER,
                    font=("Segoe UI", 12, "bold"), relief="flat", cursor="hand2", padx=20).pack(side="right", ipady=8)

    def on_show(self):
        self.textbox.delete("1.0", tk.END)
        self.update_count()

    def update_count(self, event=None):
        length = len(self.textbox.get("1.0", tk.END).strip())
        rem = 280 - length
        self.count_lbl.config(text=f"{rem} remaining", foreground=DANGER if rem < 0 else DIM_TEXT)

    def post(self):
        if session.get("is_admin"):
            messagebox.showerror("Admin", "Admins cannot post tweets.")
            return
        content = self.textbox.get("1.0", tk.END).strip()
        if not content or len(content) > 280:
            messagebox.showerror("Limit", "Tweet must be 1-280 characters.")
            return
        db.create_tweet(session["user"]["reg_no"], content)
        self.controller.show_frame(HomeFeedScreen)


class ProfileScreen(FeedBaseScreen):
    def __init__(self, parent, controller):
        super().__init__(parent, controller, "Profile")
        self.target_id = None

    def on_show(self, target_id=None):
        if target_id is not None:
            self.target_id = target_id
            
        for w in self.scroll.scrollable_frame.winfo_children(): w.destroy()
        
        prof = db.get_user_profile(self.target_id, session["user"]["reg_no"])
        if not prof: return

        info_panel = tk.Frame(self.scroll.scrollable_frame, bg=BG_COLOR)
        info_panel.pack(fill="x", pady=(0, 20))

        # Big Profile Header
        header_card = tk.Frame(info_panel, bg=CARD_BG, padx=25, pady=25)
        header_card.pack(fill="x")

        ttk.Label(header_card, text=prof['full_name'], font=("Segoe UI", 24, "bold"), background=CARD_BG, foreground=TEXT_COLOR).pack(anchor="w")
        ttk.Label(header_card, text=f"@{prof['reg_no']}  •  {prof['department']} '{(prof['batch_year'])}", style="DimCard.TLabel").pack(anchor="w", pady=(2, 15))
        
        stats = tk.Frame(header_card, bg=CARD_BG)
        stats.pack(anchor="w", pady=5)
        ttk.Label(stats, text=f"{prof['following_count']} Following    {prof['follower_count']} Followers", style="BoldCard.TLabel").pack(side="left")

        # Action Buttons
        if self.target_id != session["user"]["reg_no"]:
            acts = tk.Frame(header_card, bg=CARD_BG)
            acts.pack(anchor="w", pady=(20, 0))
            
            is_following = prof['is_following_by_caller']
            btn_text = "Following" if is_following else "Follow"
            btn_bg = CARD_BG if is_following else TEXT_COLOR
            btn_fg = TEXT_COLOR if is_following else BG_COLOR
            
            HoverButton(acts, text=btn_text, command=self.toggle_follow, bg=btn_bg, fg=btn_fg,
                        font=("Segoe UI", 12, "bold"), relief="solid", borderwidth=1, cursor="hand2", width=12).pack(side="left", ipady=5)
            
            HoverButton(acts, text="✉ Message", command=lambda: self.controller.show_frame(ConversationScreen, partner_id=self.target_id),
                        bg=CARD_BG, fg=TEXT_COLOR, font=("Segoe UI", 12, "bold"), relief="solid", borderwidth=1, cursor="hand2").pack(side="left", padx=10, ipady=5)

        tweets = db.get_user_tweets(self.target_id, 0, 20)
        self.render_tweets(tweets, clear=False)

    def toggle_follow(self):
        db.toggle_follow(session["user"]["reg_no"], self.target_id)
        self.on_show(self.target_id)


class TweetDetailScreen(tk.Frame):
    def __init__(self, parent, controller):
        super().__init__(parent, bg=BG_COLOR)
        self.controller = controller
        self.tweet_id = None
        
        top = tk.Frame(self, bg=BG_COLOR)
        top.pack(fill="x", padx=20, pady=20)
        HoverButton(top, text="← Back", command=lambda: controller.show_frame(HomeFeedScreen), bg=BG_COLOR, fg=TEXT_COLOR, relief="flat", font=("Segoe UI", 14, "bold"), cursor="hand2").pack(side="left")
        
        self.scroll = ScrollableFrame(self)
        self.scroll.pack(fill="both", expand=True, padx=20)

    def on_show(self, tweet_id=None):
        self.tweet_id = tweet_id
        for w in self.scroll.scrollable_frame.winfo_children(): w.destroy()
        
        t = db.get_tweet_by_id(self.tweet_id)
        if not t: return

        # Main Tweet
        card = tk.Frame(self.scroll.scrollable_frame, bg=CARD_BG, padx=20, pady=20)
        card.pack(fill="x", pady=(0, 20))
        ttk.Label(card, text=t['full_name'], style="Header.Card.TLabel").pack(anchor="w")
        ttk.Label(card, text=f"@{t['reg_no']}", style="DimCard.TLabel").pack(anchor="w")
        ttk.Label(card, text=t['content'], font=("Segoe UI", 18), background=CARD_BG, foreground=TEXT_COLOR, wraplength=700).pack(anchor="w", pady=20)

        # Reply Box
        rep_box = tk.Frame(self.scroll.scrollable_frame, bg=BG_COLOR)
        rep_box.pack(fill="x", pady=10)
        self.r_text = tk.Text(rep_box, bg=CARD_BG, fg=TEXT_COLOR, insertbackground=TEXT_COLOR, font=("Segoe UI", 12), height=3, relief="flat")
        self.r_text.pack(fill="x")
        HoverButton(rep_box, text="Reply", command=self.add_reply, bg=ACCENT, fg=TEXT_COLOR, activebackground=ACCENT_HOVER, font=("Segoe UI", 11, "bold"), relief="flat", cursor="hand2").pack(anchor="e", pady=10, ipady=5, ipadx=10)

        # Replies
        replies = db.get_replies(self.tweet_id)
        for r in replies:
            pad = (r['depth'] - 1) * 30
            rf = tk.Frame(self.scroll.scrollable_frame, bg=CARD_BG, padx=15, pady=10)
            rf.pack(fill="x", padx=(pad, 0), pady=2)
            ttk.Label(rf, text=f"{r['author_name']} @{r['author_reg_no']}", style="BoldCard.TLabel").pack(anchor="w")
            ttk.Label(rf, text=r['content'], style="Card.TLabel", wraplength=600).pack(anchor="w", pady=5)

    def add_reply(self):
        if session.get("is_admin"):
            messagebox.showerror("Admin", "Admins cannot reply to tweets.")
            return
        txt = self.r_text.get("1.0", tk.END).strip()
        if txt:
            db.add_reply(self.tweet_id, session["user"]["reg_no"], None, txt)
            self.on_show(self.tweet_id)


class SearchScreen(tk.Frame):
    def __init__(self, parent, controller):
        super().__init__(parent, bg=BG_COLOR)
        self.controller = controller
        
        top = tk.Frame(self, bg=BG_COLOR)
        top.pack(fill="x", padx=30, pady=20)
        ttk.Label(top, text="Search", style="Header.TLabel").pack(anchor="w", pady=(0, 10))
        
        self.query_var = tk.StringVar()
        s_entry = tk.Entry(top, textvariable=self.query_var, bg=CARD_BG, fg=TEXT_COLOR, insertbackground=TEXT_COLOR, font=("Segoe UI", 14), relief="flat")
        s_entry.pack(fill="x", ipady=10)
        
        btn_f = tk.Frame(top, bg=BG_COLOR)
        btn_f.pack(fill="x", pady=10)
        HoverButton(btn_f, text="Search Users", command=self.s_users, bg=CARD_BG, fg=TEXT_COLOR, activebackground="#22303c", font=("Segoe UI", 12), relief="flat").pack(side="left", padx=(0, 10), ipady=5, ipadx=10)
        HoverButton(btn_f, text="Search Tweets", command=self.s_tweets, bg=CARD_BG, fg=TEXT_COLOR, activebackground="#22303c", font=("Segoe UI", 12), relief="flat").pack(side="left", ipady=5, ipadx=10)
        
        self.scroll = ScrollableFrame(self)
        self.scroll.pack(fill="both", expand=True, padx=30)

    def s_users(self):
        for w in self.scroll.scrollable_frame.winfo_children(): w.destroy()
        res = db.search_users(self.query_var.get())
        for u in res:
            card = tk.Frame(self.scroll.scrollable_frame, bg=CARD_BG, pady=15, padx=20)
            card.pack(fill="x", pady=5)
            HoverButton(card, text=f"{u['full_name']} (@{u['reg_no']}) - {u['department']}", command=lambda r=u['reg_no']: self.controller.show_frame(ProfileScreen, target_id=r),
                        bg=CARD_BG, fg=TEXT_COLOR, activebackground="#22303c", hover_color="#22303c", font=("Segoe UI", 14, "bold"), relief="flat", anchor="w", cursor="hand2").pack(fill="x")

    def s_tweets(self):
        for w in self.scroll.scrollable_frame.winfo_children(): w.destroy()
        res = db.search_tweets(self.query_var.get())
        for t in res:
            card = tk.Frame(self.scroll.scrollable_frame, bg=CARD_BG, pady=15, padx=20)
            card.pack(fill="x", pady=5)
            ttk.Label(card, text=f"@{t['reg_no']}", style="DimCard.TLabel").pack(anchor="w")
            ttk.Label(card, text=t['content'], style="Card.TLabel", wraplength=600).pack(anchor="w", pady=(5,0))


class InboxScreen(tk.Frame):
    def __init__(self, parent, controller):
        super().__init__(parent, bg=BG_COLOR)
        self.controller = controller
        
        ttk.Label(self, text="Messages", style="Header.TLabel").pack(anchor="w", padx=30, pady=20)
        self.scroll = ScrollableFrame(self)
        self.scroll.pack(fill="both", expand=True, padx=30)

    def on_show(self):
        for w in self.scroll.scrollable_frame.winfo_children(): w.destroy()
        convs = db.get_inbox(session["user"]["reg_no"])
        
        if not convs:
            ttk.Label(self.scroll.scrollable_frame, text="No messages yet.", style="DimCard.TLabel").pack(pady=20)
            
        for c in convs:
            card = tk.Frame(self.scroll.scrollable_frame, bg=CARD_BG, padx=20, pady=15)
            card.pack(fill="x", pady=5)
            btn = HoverButton(card, text=f"@{c['partner_reg_no']}\n\n{c['latest_message'][:50]}...", 
                              command=lambda p=c['partner_reg_no']: self.controller.show_frame(ConversationScreen, partner_id=p),
                              bg=CARD_BG, fg=TEXT_COLOR, activebackground="#22303c", hover_color="#22303c", font=("Segoe UI", 12), relief="flat", anchor="w", justify="left", cursor="hand2")
            btn.pack(fill="x")


class ConversationScreen(tk.Frame):
    def __init__(self, parent, controller):
        super().__init__(parent, bg=BG_COLOR)
        self.controller = controller
        self.partner_id = None
        
        self.header = ttk.Label(self, text="Chat", style="Header.TLabel")
        self.header.pack(anchor="w", padx=30, pady=20)
        
        self.scroll = ScrollableFrame(self)
        self.scroll.pack(fill="both", expand=True, padx=30)
        
        bot = tk.Frame(self, bg=CARD_BG, padx=20, pady=15)
        bot.pack(fill="x")
        self.msg_entry = tk.Entry(bot, bg=BG_COLOR, fg=TEXT_COLOR, insertbackground=TEXT_COLOR, font=("Segoe UI", 14), relief="flat")
        self.msg_entry.pack(side="left", fill="x", expand=True, ipady=8, padx=(0, 15))
        HoverButton(bot, text="Send", command=self.send_message, bg=ACCENT, fg=TEXT_COLOR, activebackground=ACCENT_HOVER, font=("Segoe UI", 12, "bold"), relief="flat", cursor="hand2").pack(side="right", ipady=6, ipadx=15)

    def on_show(self, partner_id=None):
        if partner_id: self.partner_id = partner_id
        self.header.config(text=f"Chat with @{self.partner_id}")
        
        for w in self.scroll.scrollable_frame.winfo_children(): w.destroy()
        msgs = db.get_conversation(session["user"]["reg_no"], self.partner_id, 0, 50)
        for m in reversed(msgs):
            is_me = m['sender_reg_no'] == session["user"]["reg_no"]
            bg_c = ACCENT if is_me else CARD_BG
            align = "e" if is_me else "w"
            pad_x = (100, 0) if is_me else (0, 100)
            
            f = tk.Frame(self.scroll.scrollable_frame, bg=BG_COLOR)
            f.pack(fill="x", pady=5)
            tk.Label(f, text=m['content'], bg=bg_c, fg=TEXT_COLOR, font=("Segoe UI", 12), padx=15, pady=10, wraplength=400, justify="left").pack(anchor=align, padx=pad_x)

    def send_message(self):
        txt = self.msg_entry.get().strip()
        if txt:
            db.send_message(session["user"]["reg_no"], self.partner_id, txt)
            self.msg_entry.delete(0, tk.END)
            self.on_show()


class AdminScreen(tk.Frame):
    def __init__(self, parent, controller):
        super().__init__(parent, bg=BG_COLOR)
        self.controller = controller
        ttk.Label(self, text="Admin Dashboard - Reports", style="Title.TLabel").pack(anchor="w", padx=30, pady=20)
        self.scroll = ScrollableFrame(self)
        self.scroll.pack(fill="both", expand=True, padx=30)

    def on_show(self):
        for w in self.scroll.scrollable_frame.winfo_children(): w.destroy()
        reports = db.get_pending_reports(0, 50)
        if not reports:
            ttk.Label(self.scroll.scrollable_frame, text="No pending reports. Great!", style="DimCard.TLabel").pack(pady=20)
            
        for r in reports:
            card = tk.Frame(self.scroll.scrollable_frame, bg=CARD_BG, padx=20, pady=15)
            card.pack(fill="x", pady=5)
            
            tgt = f"Tweet: {r['tweet_preview']}" if r['reported_tweet_id'] else f"User: @{r['reported_user_reg_no']}"
            ttk.Label(card, text=f"Report #{r['report_id']} by @{r['reporter_reg_no']} | Date: {r['report_date'].strftime('%Y-%m-%d')}", style="DimCard.TLabel").pack(anchor="w")
            ttk.Label(card, text=f"Reason: {r['reason']}", style="BoldCard.TLabel").pack(anchor="w", pady=(10, 5))
            ttk.Label(card, text=tgt, style="Card.TLabel").pack(anchor="w", pady=(0, 15))
            
            acts = tk.Frame(card, bg=CARD_BG)
            acts.pack(fill="x")
            HoverButton(acts, text="Resolve & Delete Target", command=lambda rid=r['report_id']: self.resolve(rid, True), bg=DANGER, fg=TEXT_COLOR, font=("Segoe UI", 10, "bold"), relief="flat", cursor="hand2").pack(side="left", padx=(0, 10), ipady=5, ipadx=10)
            HoverButton(acts, text="Dismiss Report", command=lambda rid=r['report_id']: self.resolve(rid, False), bg="#38444d", fg=TEXT_COLOR, font=("Segoe UI", 10, "bold"), relief="flat", cursor="hand2").pack(side="left", ipady=5, ipadx=10)

    def resolve(self, report_id, is_delete):
        if is_delete: db.resolve_report_delete(report_id, 1)
        else: db.resolve_report_dismiss(report_id, 1)
        self.on_show()

if __name__ == "__main__":
    app = UniTweetApp()
    app.mainloop()
