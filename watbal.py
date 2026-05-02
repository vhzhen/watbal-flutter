import json
import os
import requests
from bs4 import BeautifulSoup
from playwright.sync_api import sync_playwright

STATE_FILE = "cookies.json"
BASE_URL = "https://secure.touchnet.net/C22566_oneweb"

def login_with_playwright():
    """Polls for session cookies without aggressive event listeners."""
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=False)
        context = browser.new_context()
        page = context.new_page()
        
        page.goto(f"{BASE_URL}/Account/Dashboard")
        print("Please authenticate. Script will auto-close on success...")

        # Poll for the cookie instead of using 'requestfinished'
        # This prevents the "glitching" caused by event-driven saves
        found = False
        for _ in range(480):  # 2 minute timeout
            cookies = context.cookies()
            # Check for the specific app session cookie
            if any(c['name'] == 'ASP.NET_OneWebLang' for c in cookies):
                print("Session secured! Closing...")
                context.storage_state(path=STATE_FILE)
                found = True
                break
            
            page.wait_for_timeout(100) # Poll every 0.1 seconds
        
        if not found:
            print("Login timed out or cookie not found.")
            
        browser.close()

def get_session():
    if not os.path.exists(STATE_FILE): return None
    session = requests.Session()
    with open(STATE_FILE, "r") as f:
        state = json.load(f)
    for c in state["cookies"]:
        session.cookies.set(c["name"], c["value"], domain=c.get("domain"), path=c.get("path", "/"))
    return session

def get_token(session):
    try:
        # User-Agent consistency helps prevent session drops
        headers = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"}
        res = session.get(f"{BASE_URL}/Account/Dashboard", headers=headers, timeout=1)
        if "Login" in res.url and "Dashboard" not in res.url: return None
        soup = BeautifulSoup(res.text, "html.parser")
        tag = soup.find("input", {"name": "__RequestVerificationToken"})
        return tag.get("value") if tag else None
    except:
        return None

def get_balance(session, token):
    url = f"{BASE_URL}/Deposit/Home/Balances"
    headers = {
        "X-Requested-With": "XMLHttpRequest",
        "Referer": f"{BASE_URL}/Deposit",
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
    }
    res = session.post(url, headers=headers, data={"__RequestVerificationToken": token})
    return res.text

def parse_balance(html):
    soup = BeautifulSoup(html, "html.parser")
    flex = soup.find("div", title="FLEXIBLE")
    if flex:
        return flex.find_parent("tr").find_all("td")[-2].get_text(strip=True)
    return None

def main():
    session = get_session()
    token = get_token(session) if session else None

    if not token:
        login_with_playwright()
        session = get_session()
        token = get_token(session)

    if token:
        html = get_balance(session, token)
        amount = parse_balance(html)
        print(amount if amount else "Balance not found.")
    else:
        print("Auth failed.")

if __name__ == "__main__":
    main()