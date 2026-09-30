with open('src/Order.tsx', 'r') as f:
    text = f.read()

# Change 'apply' to 'take'
text = text.replace("execute('apply',", "execute('take',")
text = text.replace("order.my_offer?", "false?")

# Remove offers section completely since we removed the 2-step process
import re
text = re.sub(r"\{order\.is_owner&&order\.status==='PUBLISHED'&&<div className=\"offers\">.*?</div>\n?", "", text, flags=re.DOTALL)

with open('src/Order.tsx', 'w') as f:
    f.write(text)
