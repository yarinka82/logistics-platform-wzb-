with open('src/App.tsx', 'r') as f:
    text = f.read()

text = text.replace("location.protocol", "window.location.protocol")
text = text.replace("location.host", "window.location.host")

with open('src/App.tsx', 'w') as f:
    f.write(text)
