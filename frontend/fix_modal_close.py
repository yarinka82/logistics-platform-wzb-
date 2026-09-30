with open('src/App.tsx', 'r') as f:
    text = f.read()

# Remove window.history.replaceState from onClose and onLogin in App.tsx
text = text.replace("window.history.replaceState(null,'','/')", "")
text = text.replace("history.replaceState(null,'','/')", "")

with open('src/App.tsx', 'w') as f:
    f.write(text)
